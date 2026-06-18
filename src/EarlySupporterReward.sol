// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title EarlySupporterReward — Final Hardened Version
 *
 * Fixes applied:
 *  1. Per-user contribution stored in mapping (future-proof refund logic)
 *  2. Pull-over-Push pattern — failed transfers stored as pending withdrawals
 *  3. Loop bounded at 3 — gas safe (noted in comments)
 *  4. Decentralization guard — time-locked viral trigger (72h deadline)
 *     If creator doesn't act in time, ANY supporter can trigger viral.
 *     If viral threshold (3) not reached in time, supporters can self-refund.
 *
 * All prior fixes retained:
 *  - .call() instead of .transfer()
 *  - Manual nonReentrant guard
 *  - Requires exactly 3 supporters before markViral()
 *  - abandonContent() for refund
 *
 * SUPPORTER BENEFIT:
 *  - Creator must pay CREATOR_SEED (0.03 ETH) when registering content.
 *  - This seed is added to the pool on top of the 3 × 0.01 ETH from supporters.
 *  - Total pool = 0.06 ETH → each of the 3 supporters receives 0.02 ETH
 *    (double their 0.01 ETH stake — a 100% return).
 *  - If content is abandoned, the creator seed is refunded to the creator
 *    and each supporter gets their 0.01 ETH back.
 */
contract EarlySupporterReward {

    // ─────────────────────────────────────────────
    // Reentrancy Guard (manual — no import needed)
    // ─────────────────────────────────────────────
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    constructor() { _status = _NOT_ENTERED; }

    modifier nonReentrant() {
        require(_status != _ENTERED, "Reentrant call");
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    // ─────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────
    uint256 public constant SUPPORT_AMOUNT  = 0.01 ether;
    uint256 public constant MAX_SUPPORTERS  = 3;   // changed from 5 → 3

    /**
     * @dev Creator must seed the pool with this amount on registerContent.
     *      Pool = CREATOR_SEED + (MAX_SUPPORTERS × SUPPORT_AMOUNT)
     *           = 0.03 ETH + (3 × 0.01 ETH) = 0.06 ETH
     *      Reward per supporter = 0.06 ETH / 3 = 0.02 ETH (100% profit on 0.01 ETH stake).
     */
    uint256 public constant CREATOR_SEED    = 0.03 ether;

    /**
     * @dev After VIRAL_WINDOW seconds from registration, if 5 supporters
     *      have joined but creator hasn't triggered viral, ANY supporter
     *      can call markViral(). This removes single-point-of-control.
     *      72 hours chosen — long enough for creators, short enough to
     *      prevent indefinite lock.
     */
    uint256 public constant VIRAL_WINDOW    = 72 hours;

    /**
     * @dev After REFUND_WINDOW seconds, if content never reached 5
     *      supporters, each supporter can claim their own refund
     *      independently (Pull pattern) — no creator needed.
     */
    uint256 public constant REFUND_WINDOW   = 7 days;

    // ─────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────
    uint256 public contentCount = 0;

    // ─────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────
    event ContentRegistered(uint256 indexed contentId, address indexed creator, string title);
    event Supported(uint256 indexed contentId, address indexed supporter, uint256 position);
    event ViralTriggered(uint256 indexed contentId, uint256 totalPool, uint256 rewardPerSupporter);
    event ContentAbandoned(uint256 indexed contentId, uint256 refundedCount);
    event WithdrawalPending(uint256 indexed contentId, address indexed supporter, uint256 amount);
    event WithdrawalClaimed(address indexed claimer, uint256 amount);
    event SelfRefundClaimed(uint256 indexed contentId, address indexed supporter, uint256 amount);

    // ─────────────────────────────────────────────
    // Data Structures
    // ─────────────────────────────────────────────
    struct Content {
        address   creator;
        string    title;
        string    descriptionHash;
        address[] supporters;       // strictly ordered by arrival
        uint256   poolAmount;
        bool      isViral;
        bool      isAbandoned;
        uint256   registeredAt;     // timestamp for time-lock logic
    }

    // contentId => Content
    mapping(uint256 => Content) private contents;

    // contentId => wallet => amount paid (FIX 1: per-user contribution)
    mapping(uint256 => mapping(address => uint256)) public contributions;

    // contentId => wallet => has supported?
    mapping(uint256 => mapping(address => bool)) public hasSupported;

    // Pull pattern: wallet => claimable ETH from failed push (FIX 2)
    mapping(address => uint256) public pendingWithdrawals;

    // ─────────────────────────────────────────────
    // 1. Register Content
    // ─────────────────────────────────────────────

    /**
     * @notice Creator registers new content.
     *         Must send exactly CREATOR_SEED (0.05 ETH) to fund supporter rewards.
     * @param _title          Human-readable title
     * @param _descriptionHash IPFS hash or description hash
     */
    function registerContent(
        string memory _title,
        string memory _descriptionHash
    ) external payable {                                        // now payable
        require(bytes(_title).length > 0,           "Title cannot be empty");
        require(bytes(_descriptionHash).length > 0, "Description hash cannot be empty");
        require(msg.value == CREATOR_SEED,          "Must seed pool with exactly 0.03 ETH"); // creator seed

        contentCount++;

        Content storage c = contents[contentCount];
        c.creator         = msg.sender;
        c.title           = _title;
        c.descriptionHash = _descriptionHash;
        c.poolAmount      = msg.value;                          // seed pre-loads the pool
        c.isViral         = false;
        c.isAbandoned     = false;
        c.registeredAt    = block.timestamp;                    // record creation time

        // Track creator's seed as their contribution so abandonContent can refund it
        contributions[contentCount][msg.sender] = msg.value;

        emit ContentRegistered(contentCount, msg.sender, _title);
    }

    // ─────────────────────────────────────────────
    // 2. Support Content
    // ─────────────────────────────────────────────

    /**
     * @notice Send exactly 0.01 ETH to early-support content.
     *         Records supporter in strict arrival order.
     *         Rejects: creator, duplicates, 6th+ attempt, viral/abandoned content.
     * @param _contentId Content to support
     */
    function supportContent(uint256 _contentId) external payable {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");

        Content storage c = contents[_contentId];

        require(!c.isViral,                              "Content already went viral");
        require(!c.isAbandoned,                          "Content has been abandoned");
        require(msg.sender != c.creator,                 "Creator cannot support own content");
        require(msg.value == SUPPORT_AMOUNT,             "Must send exactly 0.01 ETH");
        require(!hasSupported[_contentId][msg.sender],   "Already supported this content");
        require(c.supporters.length < MAX_SUPPORTERS,    "Early support slots full (max 3)"); // 4th supporter blocked

        // Record in strict arrival order
        c.supporters.push(msg.sender);
        hasSupported[_contentId][msg.sender]    = true;
        contributions[_contentId][msg.sender]   = msg.value; // FIX 1: store exact amount paid
        c.poolAmount += msg.value;

        emit Supported(_contentId, msg.sender, c.supporters.length);
    }

    // ─────────────────────────────────────────────
    // 3. Mark Viral + Distribute (Push → Pull fallback)
    // ─────────────────────────────────────────────

    /**
     * @notice Distributes ETH pool equally among all 5 early supporters.
     *         Each supporter receives 0.02 ETH (0.01 ETH stake + 0.01 ETH profit).
     *
     *         WHO CAN CALL:
     *         - Creator: anytime once 5 supporters are in.
     *         - Any supporter: only after VIRAL_WINDOW (72h) has passed
     *           AND 5 supporters are in. (FIX 4: removes creator monopoly)
     *
     *         TRANSFER PATTERN (FIX 2):
     *         Uses Push with Pull fallback.
     *         - Tries .call() to each supporter.
     *         - If a transfer fails (e.g. malicious contract receiver),
     *           the amount is stored in pendingWithdrawals[] instead.
     *         - The failed supporter calls withdraw() to claim later.
     *         - One bad actor cannot block the entire distribution.
     *
     *         GAS NOTE (FIX 3):
     *         Loop is bounded at MAX_SUPPORTERS = 5.
     *         Worst-case gas is predictable and well within block limits.
     *
     * @param _contentId Content to mark viral
     */
    function markViral(uint256 _contentId) external nonReentrant {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");

        Content storage c = contents[_contentId];

        require(!c.isViral,                              "Content is already viral");
        require(!c.isAbandoned,                          "Content has been abandoned");
        require(c.supporters.length == MAX_SUPPORTERS,   "Need exactly 3 supporters first"); // updated to 3

        // FIX 4: Decentralization — after VIRAL_WINDOW, any supporter can trigger
        bool isCreator        = (msg.sender == c.creator);
        bool windowPassed     = (block.timestamp >= c.registeredAt + VIRAL_WINDOW);
        bool isSupporterCalling = hasSupported[_contentId][msg.sender];

        require(
            isCreator || (windowPassed && isSupporterCalling),
            "Only creator can trigger viral (or any supporter after 72h window)"
        );

        uint256 totalSupporters    = c.supporters.length;
        uint256 pool               = c.poolAmount;

        // FIX 1: reward per supporter derived from pool, not from hardcoded amount
        // pool = CREATOR_SEED + (3 × SUPPORT_AMOUNT) = 0.03 + 0.03 = 0.06 ETH
        // rewardPerSupporter = 0.06 / 3 = 0.02 ETH  (100% return on 0.01 ETH stake)
        uint256 rewardPerSupporter = pool / totalSupporters;

        // ── EFFECTS first (CEI pattern) ──
        c.isViral    = true;
        c.poolAmount = 0;

        emit ViralTriggered(_contentId, pool, rewardPerSupporter);

        // ── INTERACTIONS: Push with Pull fallback (FIX 2) ──
        // Gas note: loop bounded at 3 (FIX 3)
        uint256 successfulPushes = 0;

        for (uint256 i = 0; i < totalSupporters; i++) {
            address supporter = c.supporters[i];
            (bool sent, ) = payable(supporter).call{value: rewardPerSupporter}("");

            if (sent) {
                successfulPushes++;
            } else {
                // Failed push → store as claimable (Pull pattern)
                pendingWithdrawals[supporter] += rewardPerSupporter;
                emit WithdrawalPending(_contentId, supporter, rewardPerSupporter);
            }
        }

        // Return integer-division dust to creator
        uint256 distributed = rewardPerSupporter * totalSupporters;
        uint256 dust = pool - distributed;
        if (dust > 0) {
            (bool dustSent, ) = payable(c.creator).call{value: dust}("");
            if (!dustSent) {
                pendingWithdrawals[c.creator] += dust;
                emit WithdrawalPending(_contentId, c.creator, dust);
            }
        }
    }

    // ─────────────────────────────────────────────
    // 4. Pull Withdrawal (FIX 2 — claim failed push)
    // ─────────────────────────────────────────────

    /**
     * @notice Claim any ETH that could not be pushed to you during markViral.
     *         This is the Pull pattern fallback — called by the supporter themselves.
     */
    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        require(amount > 0, "Nothing to withdraw");

        // Effects before interaction
        pendingWithdrawals[msg.sender] = 0;

        (bool sent, ) = payable(msg.sender).call{value: amount}("");
        require(sent, "Withdrawal failed");

        emit WithdrawalClaimed(msg.sender, amount);
    }

    // ─────────────────────────────────────────────
    // 5. Creator Abandon + Refund (uses per-user contribution)
    // ─────────────────────────────────────────────

    /**
     * @notice Creator abandons content before going viral.
     *         Refunds each supporter exactly what they paid (FIX 1).
     *         Also refunds the creator's own CREATOR_SEED back to them.
     *         Uses Push with Pull fallback (FIX 2).
     * @param _contentId Content to abandon
     */
    function abandonContent(uint256 _contentId) external nonReentrant {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");

        Content storage c = contents[_contentId];

        require(msg.sender == c.creator,  "Only creator can abandon");
        require(!c.isViral,               "Cannot abandon viral content");
        require(!c.isAbandoned,           "Already abandoned");

        uint256 supporterCount = c.supporters.length;

        // ── EFFECTS ──
        c.isAbandoned = true;
        c.poolAmount  = 0;

        emit ContentAbandoned(_contentId, supporterCount);

        // ── INTERACTIONS: refund supporters using stored per-user contribution (FIX 1) ──
        // Gas: bounded at MAX_SUPPORTERS = 3 (FIX 3)
        for (uint256 i = 0; i < supporterCount; i++) {
            address supporter  = c.supporters[i];
            uint256 refundAmt  = contributions[_contentId][supporter]; // FIX 1

            if (refundAmt == 0) continue;
            contributions[_contentId][supporter] = 0; // clear before transfer

            (bool sent, ) = payable(supporter).call{value: refundAmt}("");
            if (!sent) {
                // Pull fallback (FIX 2)
                pendingWithdrawals[supporter] += refundAmt;
                emit WithdrawalPending(_contentId, supporter, refundAmt);
            }
        }

        // Refund creator's own seed
        uint256 creatorSeed = contributions[_contentId][c.creator];
        if (creatorSeed > 0) {
            contributions[_contentId][c.creator] = 0;
            (bool sent, ) = payable(c.creator).call{value: creatorSeed}("");
            if (!sent) {
                pendingWithdrawals[c.creator] += creatorSeed;
                emit WithdrawalPending(_contentId, c.creator, creatorSeed);
            }
        }
    }

    // ─────────────────────────────────────────────
    // 6. Self-Refund after REFUND_WINDOW (FIX 4 — decentralization)
    // ─────────────────────────────────────────────

    /**
     * @notice If content never reached 5 supporters AND REFUND_WINDOW (7 days)
     *         has passed AND creator never abandoned it, any supporter can
     *         claim their own refund independently.
     *         This removes the creator's ability to hold funds hostage forever.
     * @param _contentId Content that failed to fill
     */
    function claimSelfRefund(uint256 _contentId) external nonReentrant {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");

        Content storage c = contents[_contentId];

        require(!c.isViral, "Content went viral - no refund");
        require(!c.isAbandoned, "Already abandoned - use withdraw()");
        require(
            c.supporters.length < MAX_SUPPORTERS,
            "Content filled - wait for viral trigger"  // max 3
        );
        require(
            block.timestamp >= c.registeredAt + REFUND_WINDOW,
            "Refund window not yet open (7 days)"
        );
        require(
            hasSupported[_contentId][msg.sender],
            "You did not support this content"
        );

        uint256 refundAmt = contributions[_contentId][msg.sender];
        require(refundAmt > 0, "Already refunded");

        // Effects
        contributions[_contentId][msg.sender] = 0;
        c.poolAmount -= refundAmt;

        // Interaction
        (bool sent, ) = payable(msg.sender).call{value: refundAmt}("");
        require(sent, "Self-refund transfer failed");

        emit SelfRefundClaimed(_contentId, msg.sender, refundAmt);
    }

    // ─────────────────────────────────────────────
    // 7. View / Getter Functions
    // ─────────────────────────────────────────────

    /**
     * @notice Returns ordered supporter addresses for a content piece.
     */
    function getSupporters(uint256 _contentId)
        external view returns (address[] memory)
    {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");
        return contents[_contentId].supporters;
    }

    /**
     * @notice Returns full details of a content piece.
     */
    function getContent(uint256 _contentId)
        external view
        returns (
            address creator,
            string memory title,
            string memory descriptionHash,
            uint256 supporterCount,
            uint256 poolAmount,
            bool isViral,
            bool isAbandoned,
            uint256 registeredAt,
            uint256 viralWindowEnd,
            uint256 refundWindowEnd
        )
    {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");
        Content storage c = contents[_contentId];
        return (
            c.creator,
            c.title,
            c.descriptionHash,
            c.supporters.length,
            c.poolAmount,
            c.isViral,
            c.isAbandoned,
            c.registeredAt,
            c.registeredAt + VIRAL_WINDOW,
            c.registeredAt + REFUND_WINDOW
        );
    }

    /**
     * @notice Check if a wallet has supported a content piece.
     */
    function hasSupportedContent(uint256 _contentId, address _wallet)
        external view returns (bool)
    {
        return hasSupported[_contentId][_wallet];
    }

    /**
     * @notice How many ETH slots remain open.
     */
    function slotsRemaining(uint256 _contentId)
        external view returns (uint256)
    {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");
        uint256 filled = contents[_contentId].supporters.length;
        return filled >= MAX_SUPPORTERS ? 0 : MAX_SUPPORTERS - filled;
    }

    /**
     * @notice How many seconds until the viral window opens for community trigger.
     *         Returns 0 if window is already open.
     */
    function timeUntilViralWindow(uint256 _contentId)
        external view returns (uint256)
    {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");
        uint256 deadline = contents[_contentId].registeredAt + VIRAL_WINDOW;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice How many seconds until the self-refund window opens.
     *         Returns 0 if already open.
     */
    function timeUntilRefundWindow(uint256 _contentId)
        external view returns (uint256)
    {
        require(_contentId > 0 && _contentId <= contentCount, "Invalid content ID");
        uint256 deadline = contents[_contentId].registeredAt + REFUND_WINDOW;
        if (block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /**
     * @notice Returns how much ETH a specific wallet contributed to a content.
     */
    function getContribution(uint256 _contentId, address _wallet)
        external view returns (uint256)
    {
        return contributions[_contentId][_wallet];
    }

    /**
     * @notice Returns claimable pending withdrawal amount for a wallet.
     */
    function getPendingWithdrawal(address _wallet)
        external view returns (uint256)
    {
        return pendingWithdrawals[_wallet];
    }
}
