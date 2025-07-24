# erc4626-solana

## What is ERC4626 on Solana?

ERC‑4626 is a Tokenized Vault Standard that defines a canonical interface for vaults that accept a single underlying ERC‑20 asset and issue share tokens representing proportional ownership. It formalises the deposit/mint/withdraw/redeem lifecycle, plus view functions for safe off‑chain previews.

### Key Characteristics
- Single‑asset custody: Vault holds one ERC‑20; all math expressed in that asset.
- Share accounting: totalAssets() ↔ totalSupply(); convertToShares() & convertToAssets() guarantee predictable ratios.
- Composable interface: DEXes, aggregators, and front‑ends can integrate any compliant vault without custom adapters.
- Strategy‑agnostic: Yield farming, lending, staking, or delta‑neutral - strategy lives behind the same facade.


## Solana Program & Account Model
What exactly is a 'Program'?
Solana Programs are shared ELF‑BPF binaries deployed once and reused forever. They are pure logic - stateless, immutable, upgradeable only via a governance‑controlled “ProgramData” account.

(Latex)

Deployment feel: Think of Uniswap‑v2 Router being the only swap contract you’ll ever deploy; every new liquidity pool would instead be a new data account the Router controls.

### Accounts = Storage Containers
When you create an account on Solana, you first specify its exact data size (for example, space = 128 bytes). The blockchain then reserves that amount of storage, and you deposit lamports (the network’s fee currency) in proportion to the size. If the deposit meets the rent‑exempt threshold, the account never pays ongoing rent. Each account also has an owner field that stores the public key of a specific program, and only that program can modify the account’s data; any transaction from another program cannot alter it.

### PDA (Program‑Derived Address)
A Program Derived Address (PDA) is generated deterministically from a program ID and a fixed set of seeds, so it has no private key. Because it cannot sign transactions off‑chain, the Solana runtime supplies a synthetic signature when the program calls invoke_signed(), treating the PDA as if it had signed. This lets the program use the PDA like its own wallet, holding mint authority, token accounts, or configuration data, while eliminating any risk of key theft or forged permissions. In effect, the PDA itself becomes the owner, replacing Solidity’s onlyOwner pattern with Solana’s built‑in authority model.

#### CPI (Cross‑Program Invocation)
The token::transfer(...) call above makes a cross‑program invocation to the SPL Token program. It serves the same purpose as IERC20.transferFrom on Ethereum, but in Solana’s account model you must provide every account (from, to, authority) along with the PDA signer seeds that the callee will read or write. Before the instruction runs, the runtime verifies that each account has the required writable or signer permissions, so the transfer executes atomically and leaves no room for dynamic reentrancy exploits.

## Authoritative Flow in an ERC‑4626‑style Vault Deposit
**Deposit**
- Tx includes: user’s Token Account (signer), Vault Token Account (writable), Share Mint (writable), Vault State PDA (writable).
- CPI #1 → spl_token::transfer user → vault.
﻿- CPI #2 → spl_token::mint_to shares → user.

**Withdraw / Redeem**
- Reverse order: burn shares → transfer underlying out.

**State Update inside the program (vault_state.total_assets += amount)**

Because every account touched is explicit in the Tx, wallets can simulate side effects and show accurate previews to users at signing time.

## What Does a Token Extension Program for ERC-4626 Look Like?
This contract implements a vault that follows the ERC 4626 economic model while using an external Spl20 token as its underlying asset. In the constructor it records the Spl20 contract address and that token’s mint address, then queries the token’s decimal places (assetDecimals) through the Spl20 interface. The vault’s total assets are retrieved in the totalAssets function by calling getTokenAccount on the Spl20 contract and reading the balance held by this contract address. Based on that value, convertToShares and convertToAssets keep the correct proportion between underlying assets and vault shares.

Shares are not issued through a separate token contract; they are tracked with simple shareBalance and shareAllowance mappings, and the _mint and _burn functions update the overall share supply (totalShareSupply). During a deposit the contract first checks that the incoming asset amount is greater than zero, moves those assets into the vault with spl20.transfer, calculates the proportional share amount, and credits it to the receiver. During a redemption it verifies ownership or allowance, burns the specified shares, and sends the corresponding amount of underlying assets back to the receiver through another spl20.transfer.

A custom nonReentrant modifier guards both state‑changing functions. It sets a locked flag on entry to block nested calls and clears it on exit, preventing reentrancy attacks. Overall the contract provides a minimal ERC 4626‑style vault that mints and burns internal shares as users deposit and withdraw Spl20 tokens, maintains the asset‑to‑share ratio, and includes basic approval logic and reentrancy protection while avoiding reliance on an external share token implementation.

(Solidity file)

## How to do ERC4626 on Solana

### 1. conceptual map
| Piece                      | On‑chain Object                      | Purpose                                                                   |
|----------------------------|--------------------------------------|---------------------------------------------------------------------------|
| Underlying Mint            | Mint (already exists)                | The ERC‑20‑equivalent asset (e.g., **USDC**)                              |
| Share Mint                 | New Mint (PDA authority)             | Tracks proportional ownership of the vault                                |
| Vault ATA                  | Token Account (owned by PDA)         | Holds the underlying assets                                               |
| Vault State PDA            | Small data account                   | Stores `share_mint`, `pda_bump`, optional fees                            |
| Token Account Owner PDA    | Signer PDA                           | Authority over Vault ATA and Share Mint                                   |

one tx always moves exactly one underlying asset and, if necessary, mints/burns the exact proportional number of shares. everything else is bookkeeping.

### 2. end‑to‑end call flow (simplified)
1) deposit (assets → shares)

2) tx composer (wallet)
- adds: user ata, vault ata, share mint, vault state, pda, token program
- invokes program deposit(assets)

3) Program
- token::transfer (user → vault)
- compute shares = assets * total_supply / total_assets
- token::mint_to (shares → user) using token_account_owner_pda as signer
- update vault_state.total_assets (optional, can always recompute)
- emit DepositEvt

4) wallet preview: because every account is explicit, it can show -X assets & +Y shares before signing.

5) redeem / withdraw (shares → assets) is the same sequence in reverse order.

### 3. Write program
Imagine launching a tiny Solana vault that behaves like an ERC‑4626 clone. At initialization a single transaction seeds three key PDAs: a VaultState account that records the share‑mint address and bump, a program‑owned share mint, and a token‑vault account that will hold the underlying asset. The same PDA signer, token_account_owner_pda, is cached inside VaultState, letting the program act as custodian without ever exposing a private key. When a user calls deposit, the vault pulls their tokens in, mints proportional “shares,” and emits a DepositEvt, giving indexers an audit trail. The first depositor enjoys a 1 : 1 exchange rate, while later deposits use the classic supply × assets / totalAssets formula to keep shares aligned with vault value. Conversely, redeem burns the user’s shares, computes their slice of the pot, and ships the underlying tokens back out, firing a WithdrawEvt for good measure. Both CPI flows rely purely on token::transfer, mint_to, and burn, so Anchor’s safety checks guard every balance change. No yield strategy or fee logic is baked in; this snippet is the minimalist chassis you’d plug a strategy into. About ninety lines of Rust, yet it delivers the full “deposit, mint, withdraw, redeem” life‑cycle familiar to anyone who has integrated an ERC‑4626 vault on Ethereum.

(Solidity file) 
