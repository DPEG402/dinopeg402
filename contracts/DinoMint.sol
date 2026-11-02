// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {ECDSA} from "solady/utils/ECDSA.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {DinoPeg402} from "./DinoPeg402.sol";
import {IAgentRegistry, IPancakeFactory, IPancakeRouter, IPancakePair} from "./Interfaces.sol";

/// @title DinoMint
/// @notice Agent-gated, x402-paid fair-mint for DinoPeg402. Holds all the trust logic.
///
/// @dev x402 PAYMENT MODEL (corrected, verified on-chain):
///      BSC-USDT (0x55d3...7955) is a plain BEP20 — NO EIP-2612 permit, NO EIP-3009. So we do NOT
///      pull USDT via Permit2/permit/transferWithAuthorization. baw's x402 settles as a PLAIN USDT
///      transfer from the agent to `payTo` (= THIS contract), executed by baw's gas-sponsored
///      relayer. This contract is always the recipient, never a Permit2 spender/facilitator.
///
///      Two mint paths:
///        1. processMint() — voucher-gated. USDT lands here via plain transfer; a backend-signer
///           EIP-712 voucher binds ONE x402 payment (payer + exact cost + x402 nonce + deadline) to
///           ONE mint, AGAINST already-received USDT. Anyone (our keeper) may relay it.
///        2. mintDirect() — trustless fallback. Agent pre-approves USDT; contract does
///           transferFrom then mints atomically; gated by the .ai registry. Agent pays gas. This
///           path is fully trustless — immune to any backend-signer compromise.
///
/// @dev ANTI-RUG invariants (the point — enforced in code):
///      - NO owner/admin/signer withdraw of ESCROW, POOL, or LP anywhere. No such function exists.
///        The ONLY USDT exits are refund() (pre-open), _open()/_addLiquidity (LP-seed + 20% ->
///        treasury), and reclaimUnaccounted() (which can ONLY move UNACCOUNTED USDT — never the
///        accounted escrow that backs minted tokens / the pool / refunds).
///      - LP tokens are always minted directly to DEAD — never to owner/treasury.
///      - admin + backend signer are renounced/frozen at open. No blacklist. No pause.
///      - refund() cannot be blocked by anything.
///
/// @dev RESIDUAL TRUST (honest — do NOT overstate "signer has zero fund power"): a plain USDT
///      transfer records no on-chain sender, so the backend signer is the only attestation of WHO
///      paid and HOW MUCH. A COMPROMISED backendSigner could therefore (a) mint tokens to an
///      address it chooses against orphaned/unaccounted USDT, or (b) redirect orphaned/unaccounted
///      USDT via reclaimUnaccounted(). In BOTH cases the damage is bounded to UNACCOUNTED USDT: the
///      signer can NEVER touch accounted escrow, the pool, or LP, and can never mint beyond the
///      USDT actually received. Run the signer in an HSM/MPC. The mintDirect() path stays immune.
contract DinoMint is EIP712, ReentrancyGuard {
    using SafeTransferLib for address;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                    BSC MAINNET ADDRESSES                    */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    // Immutable so unit tests can inject mocks; production MUST pass the PROD_* constants below.
    IAgentRegistry public immutable registry;
    address public immutable usdt;
    IPancakeFactory public immutable factory;
    IPancakeRouter public immutable router;

    address public constant PROD_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address public constant PROD_USDT = 0x55d398326f99059fF775485246999027B3197955;
    address public constant PROD_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address public constant PROD_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev EIP-712 typehash for the mint voucher — binds payer + exact cost + x402 nonce + expiry.
    bytes32 public constant MINT_VOUCHER_TYPEHASH = keccak256(
        "MintVoucher(address payer,uint256 shares,uint256 cost,bytes32 x402Nonce,uint256 deadline)"
    );

    /// @dev EIP-712 typehash for a FREE-phase voucher (no payment).
    bytes32 public constant FREE_VOUCHER_TYPEHASH =
        keccak256("FreeVoucher(address payer,uint256 shares,bytes32 nonce,uint256 deadline)");

    /// @dev EIP-712 typehash for an unaccounted-USDT reclaim attestation.
    bytes32 public constant RECLAIM_TYPEHASH =
        keccak256("Reclaim(address to,uint256 amount,bytes32 nonce,uint256 deadline)");

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          PARAMETERS                         */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    DinoPeg402 public immutable token;
    address public immutable treasury;
    uint256 public immutable tokensPerShare; // = token.unit(); 1 share = 1 dino
    address public immutable backendSigner; // authorizes processMint vouchers; zero-fund powers

    uint256 public constant OPEN_THRESHOLD = 10_000; // shares that trigger pool open
    uint256 public constant MAX_SHARES_PER_TX = 12;
    uint256 public constant MAX_SHARES = 4_440_000; // global minter share cap (~50% of supply)
    uint256 public constant REFUND_DELAY = 7 days;

    // --- economics: free phase + flat price (no tiers) ---
    uint256 public constant FLAT_PRICE = 1e18; // $1.00/share (USDT 18-dec)
    uint256 public constant FREE_CAP = 1_000; // total free shares (global)
    uint256 public constant FREE_PER_AGENT_CAP = 5; // on-chain hard bound per agent
    uint256 public constant PAID_CAP_PER_WALLET = 12; // paid shares per wallet (across txs)

    uint256 internal constant LP_BPS = 8_000; // 80% -> liquidity
    uint256 internal constant BPS = 10_000;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                            STATE                            */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    uint256 public sharesMinted; // cumulative (free + paid) — counts toward open threshold
    uint256 public paidShares; // cumulative PAID shares (free contributes $0)
    uint256 public freeMinted; // cumulative FREE shares
    uint256 public accountedUsdt; // USDT already backing minted shares (escrow book)
    uint256 public firstMintTime;
    bool public opened;
    address public admin; // renounced (zeroed) at open; holds NO fund powers
    address public pair;

    mapping(address => uint256) public paidUsdt; // refundable pre-open
    mapping(address => uint256) public paidSharesByWallet; // paid cap enforcement (across txs)
    mapping(address => uint256) public freeUsedByAgent; // free cap enforcement per agent
    mapping(bytes32 => bool) public x402NonceUsed; // one x402 payment -> one paid mint
    mapping(bytes32 => bool) public freeNonceUsed; // free voucher replay guard
    mapping(bytes32 => bool) public reclaimNonceUsed; // reclaim attestation replay guard

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                        ERRORS / EVENTS                      */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    error NotAgent();
    error BadShareCount();
    error SoldOut();
    error AlreadyOpened();
    error RefundTooEarly();
    error NothingToRefund();
    error BadVoucher();
    error NonceUsed();
    error InsufficientReceivedUsdt();
    error VoucherExpired();
    error CostBelowPrice();
    error ExceedsUnaccounted();
    error FreeCapReached();
    error FreePerAgentCapReached();
    error PaidCapReached();

    event Minted(address indexed payer, uint256 shares, uint256 cost, bool viaVoucher);
    event FreeMinted(address indexed payer, uint256 shares);
    event Opened(uint256 usdtToLp, uint256 dpegToLp, uint256 usdtToTreasury, address pair);
    event LiquidityAdded(uint256 usdtToLp, uint256 dpegToLp, uint256 usdtToTreasury);
    event AdminRenounced();
    event Refunded(address indexed payer, uint256 amount);
    event ReclaimedUnaccounted(address indexed to, uint256 amount, bytes32 nonce);

    constructor(
        address token_,
        address treasury_,
        address backendSigner_,
        address registry_,
        address usdt_,
        address factory_,
        address router_
    ) {
        token = DinoPeg402(payable(token_));
        treasury = treasury_;
        backendSigner = backendSigner_;
        registry = IAgentRegistry(registry_);
        usdt = usdt_;
        factory = IPancakeFactory(factory_);
        router = IPancakeRouter(router_);
        tokensPerShare = DinoPeg402(payable(token_)).unit(); // 1 share = 1 dino
        admin = msg.sender;
    }

    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        name = "DinoMint";
        version = "1";
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          AGENT GATE                         */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice True iff `who` owns the Agent-ID registered under `label`.
    function isAgent(address who, string memory label) public view returns (bool) {
        uint256 id = uint256(keccak256(bytes(label)));
        try registry.ownerOf(id) returns (address o) {
            return o == who && who != address(0);
        } catch {
            return false;
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           PRICING                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Flat PAID price: every paid share costs FLAT_PRICE ($1.00). No tiers.
    function quoteCost(uint256 shares) public pure returns (uint256) {
        return shares * FLAT_PRICE;
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*            x402 ON-CHAIN DISCOVERY (anti-spoof)             */
    /*  A scanning agent can cross-check a /api/mint HTTP-402      */
    /*  response against these on-chain truths before paying.     */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Capability flag: this contract settles payments via x402.
    function supportsX402() external pure returns (bool) {
        return true;
    }

    /// @notice The x402 recipient. USDT lands at THIS contract — never an intermediary/spender.
    function x402PayTo() external view returns (address) {
        return address(this);
    }

    /// @notice The x402 payment asset (USDT on BSC).
    function x402Asset() external view returns (address) {
        return usdt;
    }

    /// @notice Human network label for the x402 `accepts[].network` cross-check.
    function x402Network() external pure returns (string memory) {
        return "bsc";
    }

    /// @notice The chain id (56 on BNB Smart Chain) for a precise network cross-check.
    function x402ChainId() external view returns (uint256) {
        return block.chainid;
    }

    /// @notice The x402 scheme.
    function x402Scheme() external pure returns (string memory) {
        return "exact";
    }

    /// @notice Price per PAID share in USDT (1e18 = $1.00). The 402 `maxAmountRequired` must equal
    ///         `shares * x402PricePerShare()`.
    function x402PricePerShare() external pure returns (uint256) {
        return FLAT_PRICE;
    }

    /// @notice EIP-712 typehash the backend signs for a mint voucher (lets an agent reconstruct it).
    function x402VoucherTypehash() external pure returns (bytes32) {
        return MINT_VOUCHER_TYPEHASH;
    }

    /// @notice EIP-712 domain name/version, so an agent can rebuild the voucher digest it verifies.
    function x402Domain() external pure returns (string memory name, string memory version) {
        return ("DinoMint", "1");
    }

    /// @notice One-call x402 discovery: (payTo, asset, chainId, scheme, pricePerShare).
    function x402PaymentInfo()
        external
        view
        returns (address payTo, address asset, uint256 chainId, string memory scheme, uint256 pricePerShare)
    {
        return (address(this), usdt, block.chainid, "exact", FLAT_PRICE);
    }

    /// @notice EIP-712 digest a backend signer signs to authorize a FREE-phase mint.
    function freeVoucherDigest(address payer, uint256 shares, bytes32 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(
            keccak256(abi.encode(FREE_VOUCHER_TYPEHASH, payer, shares, nonce, deadline))
        );
    }

    /// @notice EIP-712 digest a backend signer signs to authorize a voucher mint.
    function voucherDigest(
        address payer,
        uint256 shares,
        uint256 cost,
        bytes32 x402Nonce,
        uint256 deadline
    ) public view returns (bytes32) {
        return _hashTypedData(
            keccak256(abi.encode(MINT_VOUCHER_TYPEHASH, payer, shares, cost, x402Nonce, deadline))
        );
    }

    /// @notice EIP-712 digest a backend signer signs to attest an orphaned-USDT reclaim.
    function reclaimDigest(address to, uint256 amount, bytes32 nonce, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return _hashTypedData(keccak256(abi.encode(RECLAIM_TYPEHASH, to, amount, nonce, deadline)));
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                            MINT                             */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice PRIMARY (x402) path. USDT has already been transferred to this contract by baw's
    ///         relayer. A backend-signer voucher binds ONE x402 payment (payer + exact `cost` +
    ///         `x402Nonce` + `deadline`) to ONE mint, against received USDT. Anyone may relay.
    /// @dev Bounded-trust: the signer can ONLY mint against USDT already here, never beyond it,
    ///      never twice per payment, and never touches accounted escrow/pool/LP. See RESIDUAL TRUST.
    /// @param cost       the exact USDT the voucher/payment is for (escrowed, fully refundable).
    /// @param x402Nonce  the x402 authorization nonce — single-use (one payment, one mint).
    /// @param deadline   voucher expiry (unix seconds).
    function processMint(
        address payer,
        uint256 shares,
        uint256 cost,
        bytes32 x402Nonce,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        if (shares == 0 || shares > MAX_SHARES_PER_TX) revert BadShareCount();
        if (sharesMinted + shares > MAX_SHARES) revert SoldOut();
        if (paidSharesByWallet[payer] + shares > PAID_CAP_PER_WALLET) revert PaidCapReached();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (x402NonceUsed[x402Nonce]) revert NonceUsed();

        address rec = ECDSA.recover(voucherDigest(payer, shares, cost, x402Nonce, deadline), sig);
        if (rec != backendSigner || backendSigner == address(0)) revert BadVoucher();

        // Price-cover: the signed/paid amount must cover the flat price (prevents underpaid mint).
        if (cost < quoteCost(shares)) revert CostBelowPrice();

        // Bind the mint to USDT actually received (balance not yet backing prior shares).
        uint256 unaccounted = usdt.balanceOf(address(this)) - accountedUsdt;
        if (unaccounted < cost) revert InsufficientReceivedUsdt();

        x402NonceUsed[x402Nonce] = true;
        paidShares += shares;
        paidSharesByWallet[payer] += shares;
        // accountedUsdt/paidUsdt accrue inside _finishMint only pre-open (MED-1).
        _finishMint(payer, shares, cost, true);
    }

    /// @notice FREE-phase mint. A backend FREE voucher (payer + shares + nonce + deadline) grants
    ///         `shares` dinos at ZERO cost. No USDT, no refund credit (nothing was paid). Free
    ///         shares DO count toward the 10,000-share open threshold.
    /// @dev On-chain caps bound a compromised signer: total FREE_CAP and per-agent
    ///      FREE_PER_AGENT_CAP. The finer "1 base + invite/social bonus" logic is off-chain.
    function mintFree(
        address payer,
        uint256 shares,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        if (shares == 0 || shares > MAX_SHARES_PER_TX) revert BadShareCount();
        if (sharesMinted + shares > MAX_SHARES) revert SoldOut();
        if (freeMinted + shares > FREE_CAP) revert FreeCapReached();
        if (freeUsedByAgent[payer] + shares > FREE_PER_AGENT_CAP) revert FreePerAgentCapReached();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (freeNonceUsed[nonce]) revert NonceUsed();

        address rec = ECDSA.recover(freeVoucherDigest(payer, shares, nonce, deadline), sig);
        if (rec != backendSigner || backendSigner == address(0)) revert BadVoucher();

        freeNonceUsed[nonce] = true;
        freeMinted += shares;
        freeUsedByAgent[payer] += shares;
        _finishMint(payer, shares, 0, true); // cost 0: no escrow, no paidUsdt credit
        emit FreeMinted(payer, shares);
    }

    /// @notice Recovery for orphaned USDT: an x402 payment that landed here but for which NO voucher
    ///         was ever relayed would otherwise be stuck. The backend knows the real sender from the
    ///         x402 PAYMENT-RESPONSE and signs (to, amount, nonce, deadline) to return it.
    /// @dev HARD CONSTRAINT (anti-rug): may move ONLY UNACCOUNTED USDT — `amount` must be <= the
    ///      current unaccounted balance. It can NEVER touch accounted escrow (which backs minted
    ///      tokens / the pool / refunds), the pool, or LP. Same bounded residual trust as
    ///      processMint: a compromised signer could redirect orphaned deposits, nothing more.
    function reclaimUnaccounted(
        address to,
        uint256 amount,
        bytes32 nonce,
        uint256 deadline,
        bytes calldata sig
    ) external nonReentrant {
        if (to == address(0) || amount == 0) revert ExceedsUnaccounted();
        if (block.timestamp > deadline) revert VoucherExpired();
        if (reclaimNonceUsed[nonce]) revert NonceUsed();

        address rec = ECDSA.recover(reclaimDigest(to, amount, nonce, deadline), sig);
        if (rec != backendSigner || backendSigner == address(0)) revert BadVoucher();

        // ONLY unaccounted USDT is movable — accounted escrow is untouchable.
        uint256 unaccounted = usdt.balanceOf(address(this)) - accountedUsdt;
        if (amount > unaccounted) revert ExceedsUnaccounted();

        reclaimNonceUsed[nonce] = true;
        usdt.safeTransfer(to, amount);
        emit ReclaimedUnaccounted(to, amount, nonce);
    }

    /// @notice FALLBACK (trustless) path. Agent pre-approves USDT to this contract; we pull EXACT
    ///         cost and mint atomically. Gated by the .ai registry. Agent pays gas.
    function mintDirect(string calldata label, uint256 shares) external nonReentrant {
        address payer = msg.sender;
        if (shares == 0 || shares > MAX_SHARES_PER_TX) revert BadShareCount();
        if (sharesMinted + shares > MAX_SHARES) revert SoldOut();
        if (paidSharesByWallet[payer] + shares > PAID_CAP_PER_WALLET) revert PaidCapReached();
        if (!isAgent(payer, label)) revert NotAgent();

        uint256 cost = quoteCost(shares); // flat $1/share
        usdt.safeTransferFrom(payer, address(this), cost); // pull EXACT cost
        paidShares += shares;
        paidSharesByWallet[payer] += shares;
        // accountedUsdt/paidUsdt accrue inside _finishMint only pre-open (MED-1).
        _finishMint(payer, shares, cost, false);
    }

    /// @dev Shared tail for both paid and free mints. `cost == 0` means a free mint (no escrow,
    ///      no refund credit, no liquidity add).
    /// @dev MED-1: escrow (accountedUsdt + refundable paidUsdt) accrues ONLY pre-open. Post-open a
    ///      paid mint's USDT is deployed to the pool immediately (nothing escrowed/refundable), so
    ///      accountedUsdt stays 0 and processMint's `balanceOf - accountedUsdt` never underflows.
    function _finishMint(address payer, uint256 shares, uint256 cost, bool viaVoucher) internal {
        if (firstMintTime == 0) firstMintTime = block.timestamp;

        // mint dinos to the payer (free + paid alike)
        sharesMinted += shares;
        token.mint(payer, shares * tokensPerShare);

        if (cost != 0) emit Minted(payer, shares, cost, viaVoucher);

        if (!opened) {
            if (cost != 0) {
                // pre-open escrow (refundable until open / 7-day refund)
                paidUsdt[payer] += cost;
                accountedUsdt += cost;
            }
            if (sharesMinted >= OPEN_THRESHOLD) _open();
        } else if (cost != 0) {
            // post-open: deploy immediately, nothing escrowed (free post-open adds no liquidity)
            _addLiquidityAtMarket(cost);
        }
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                        POOL OPEN / LP                       */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function _open() internal {
        if (opened) revert AlreadyOpened();
        opened = true;

        address p = factory.getPair(address(token), usdt);
        if (p == address(0)) p = factory.createPair(address(token), usdt);
        pair = p;

        token.setPair(p);
        token.enableTrading();

        // Split ALL accumulated escrow (paid USDT only — free contributed $0): 80% LP / 20% treasury.
        uint256 usdtToLp = (accountedUsdt * LP_BPS) / BPS;
        uint256 usdtToTreasury = accountedUsdt - usdtToLp;
        // Pair against PAID shares' DPEG so the opening price tracks the flat $1 (free shares are
        // circulating with no USDT backing — intended — and must NOT dilute the seed ratio into a
        // broken opening price).
        uint256 dpegToLp = (paidShares * tokensPerShare * LP_BPS) / BPS;

        _seedLiquidity(usdtToLp, dpegToLp, usdtToTreasury);

        // MED-1: all escrow is now deployed into the pool + treasury, so the escrow book is zeroed.
        // Post-open paid mints do NOT re-accrue it, keeping processMint's `balance - accountedUsdt`
        // underflow-free for the rest of the sale.
        accountedUsdt = 0;

        emit Opened(usdtToLp, dpegToLp, usdtToTreasury, p);

        // renounce admin (admin holds NO fund powers; on-chain seal).
        admin = address(0);
        emit AdminRenounced();
    }

    /// @dev Post-open: each mint adds its own 80% USDT to the pool, 20% to treasury. The DPEG side
    ///      is computed at the LIVE reserve ratio (not the mint tier price) so addLiquidity consumes
    ///      both sides cleanly and leaves no refund dust.
    function _addLiquidityAtMarket(uint256 cost) internal {
        uint256 usdtToLp = (cost * LP_BPS) / BPS;
        uint256 usdtToTreasury = cost - usdtToLp;

        (uint256 rDpeg, uint256 rUsdt) = _reserves();
        // dpeg : usdt == rDpeg : rUsdt  ->  dpegToLp = usdtToLp * rDpeg / rUsdt
        uint256 dpegToLp = rUsdt == 0 ? 0 : (usdtToLp * rDpeg) / rUsdt;

        _seedLiquidity(usdtToLp, dpegToLp, usdtToTreasury);
        emit LiquidityAdded(usdtToLp, dpegToLp, usdtToTreasury);
    }

    /// @dev Current pool reserves as (DPEG, USDT), order-normalized.
    function _reserves() internal view returns (uint256 rDpeg, uint256 rUsdt) {
        IPancakePair p = IPancakePair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        if (p.token0() == address(token)) {
            (rDpeg, rUsdt) = (uint256(r0), uint256(r1));
        } else {
            (rDpeg, rUsdt) = (uint256(r1), uint256(r0));
        }
    }

    /// @dev Seeds liquidity WITHOUT the router quote path (HIGH-1 fix): mint the DPEG side, transfer
    ///      both sides straight to the pair, and call `pair.mint(DEAD)` ourselves so the LP is
    ///      burned to dead. This is immune to the pre-open create+donate+sync griefing attack — a
    ///      griefer's USDT/DPEG donation merely enriches the burned LP; the open can never be
    ///      bricked by a manipulated reserve/quote. Works for both the first seed and post-open adds
    ///      (UniswapV2 `mint` takes the min-proportional LP; any excess side is donated, never
    ///      reverts). 20% treasury transfer stays separate.
    function _seedLiquidity(uint256 usdtToLp, uint256 dpegToLp, uint256 usdtToTreasury) internal {
        token.mint(address(this), dpegToLp);
        address p = pair;
        usdt.safeTransfer(p, usdtToLp);
        address(token).safeTransfer(p, dpegToLp);
        IPancakePair(p).mint(DEAD); // LP minted directly to the dead address

        if (usdtToTreasury != 0) usdt.safeTransfer(treasury, usdtToTreasury);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           REFUND                            */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice If the pool never opened and 7 days have passed since the first mint, any payer may
    ///         reclaim their FULL paid USDT. Keeps accountedUsdt consistent. Permissionless;
    ///         cannot be blocked (no pause / blacklist).
    function refund() external nonReentrant {
        if (opened) revert AlreadyOpened();
        if (firstMintTime == 0 || block.timestamp <= firstMintTime + REFUND_DELAY) {
            revert RefundTooEarly();
        }
        uint256 amt = paidUsdt[msg.sender];
        if (amt == 0) revert NothingToRefund();
        paidUsdt[msg.sender] = 0;
        accountedUsdt -= amt;
        usdt.safeTransfer(msg.sender, amt);
        emit Refunded(msg.sender, amt);
    }
}
