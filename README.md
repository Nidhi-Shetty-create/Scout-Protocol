# Scout Protocol

Scout Protocol is a decentralized content discovery and reward system built using Solidity and Foundry.

## Features

- Register content on-chain
- Support creators through early contributions
- Limit early supporter slots to the first 3 supporters
- Mark content as viral
- Automatically distribute rewards to early supporters
- Prevent interactions with already viral content
- Comprehensive Foundry test suite

## Tech Stack

- Solidity
- Foundry
- Anvil
- Forge
- Cast
- GitHub Actions

## Smart Contract Functions

### registerContent(string title, string ipfsHash)

Registers new content by paying the required registration fee.

### supportContent(uint256 contentId)

Allows users to support content before it becomes viral.

### markViral(uint256 contentId)

Marks eligible content as viral and distributes rewards.

### getContent(uint256 contentId)

Returns all details associated with a content item.

## Testing

Run tests using:

```bash
forge test
```

## Local Deployment

Deploy using:

```bash
forge create src/EarlySupporterReward.sol:EarlySupporterReward \
--rpc-url http://127.0.0.1:8545 \
--private-key <PRIVATE_KEY> \
--broadcast
```

## Author

Nidhi Shetty
GitHub: https://github.com/Nidhi-Shetty-create
