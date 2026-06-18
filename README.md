# Scout Protocol

Scout Protocol is a Solidity-based economic protocol that rewards early supporters who discover promising content before it becomes viral.

## Problem

Creators often struggle to gain early support, while supporters who identify high-potential content receive no direct incentive.

Scout Protocol aligns incentives by allowing a limited number of early supporters to participate in a shared reward pool.

## How It Works

1. Creator registers content and seeds the initial pool.
2. Only the first 3 supporters can support the content.
3. Supporters contribute ETH to the reward pool.
4. If the content becomes viral, rewards are distributed automatically.
5. No further participation is allowed after finalization.

## Features

- Early supporter reward mechanism
- Fixed scarcity (maximum 3 supporters)
- Viral payout distribution
- Protection against double payouts
- CEI (Checks-Effects-Interactions) security pattern
- Foundry unit tests
- Local deployment using Anvil

## Tech Stack

- Solidity
- Foundry
- Anvil
- Forge
- Cast

## Validation Performed

- Contract deployment
- Creator registration
- Supporter onboarding
- Viral payout execution
- Double payout prevention
- Viral state enforcement
- Early supporter scarcity enforcement

## Status

Prototype completed and validated locally using Foundry and Anvil.
