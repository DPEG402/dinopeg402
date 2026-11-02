// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {DN404} from "dn404/DN404.sol";
import {DN404Mirror} from "dn404/DN404Mirror.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {IPancakeRouter, IPancakePair} from "./Interfaces.sol";

/// @dev On-chain trait renderer (DinoRenderer).
interface IDinoRenderer {
    function tokenURI(uint256 id) external view returns (string memory);
}

/// @title DinoPeg402 ($DPEG402)
/// @notice Agent-gated, x402-paid, DN-404 liquid-collectible fair-mint token on BNB Smart Chain.
///         Built on Solady/Vectorized DN404 (battle-tested ERC404 accounting — NOT hand-rolled).
///
/// @dev ANTI-HONEYPOT / ANTI-RUG invariants enforced here:
///      - Tax rates are compile-time constants with NO setter (1% accrue + 1.5% burn, buy & sell).
///      - Wallet-to-wallet and all non-pair transfers are 0% tax.
///      - No blacklist. No pause. No owner mint drain (mint is gated to the mint contract + cap).
///      - `tradingEnabled` can only be flipped ON (never back off) and only by the mint contract.
///
/// @dev SCALE NOTE: Solady DN404 stores `totalSupply` as a uint96 (max ~7.92e28 base units).
///      The headline economics are unchanged — 444T supply, 50,000,000 $DPEG402 per share — but the
///      token uses **9 decimals** so the whole thing fits uint96 with huge margin:
///        CAP  = 444e12 * 1e9 = 4.44e23  (< 2^96 ≈ 7.92e28)
///        UNIT = 50e6  * 1e9 = 5.0e16    (1 share = 1 dino)
///        theoretical max minted (4,440,000 shares + ~80% pool) ≈ 4.0e23 < CAP < 2^96.
///      `UNIT` stays an immutable constructor arg (no setter → anti-honeypot preserved); production
///      and tests both use the real PROD_UNIT. No scaled-unit workaround.
contract DinoPeg402 is DN404, Ownable, ReentrancyGuard {
    using SafeTransferLib for address;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         CONSTANTS                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    string private constant _NAME = "DinoPeg402";
    string private constant _SYMBOL = "DPEG402";

    uint8 private constant _DECIMALS = 9;

    /// @dev Real production values (9 decimals; see SCALE NOTE above).
    uint256 public constant PROD_CAP = 444_000_000_000_000 * 1e9; // 444T @ 9 dec = 4.44e23
    uint256 public constant PROD_UNIT = 50_000_000 * 1e9; // 50M per share = 5e16

    /// @dev Supply cap — mint reverts if it would be exceeded.
    uint256 public constant CAP = 444_000_000_000_000 * 1e9;

    /// @dev ASYMMETRIC tax (basis points). IMMUTABLE CONSTANTS, NO SETTER (anti-honeypot).
    ///      BUY  2.5% -> 100% treasury (no burn).
    ///      SELL 2.5% -> 1% treasury + 1.5% buyback-and-burn.
    ///      Wallet-to-wallet (and all non-pair transfers) = 0%.
    uint256 public constant BUY_TAX_BPS = 250; // 2.5% on buys -> treasury
    uint256 public constant SELL_TREASURY_BPS = 100; // 1.0% on sells -> treasury
    uint256 public constant SELL_BUYBACK_BPS = 150; // 1.5% on sells -> buyback-and-burn
    uint256 internal constant BPS = 10_000;

    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// @dev Per-call swap throttle: at most 0.1% of the pool's DPEG reserve per call.
    uint256 internal constant SWAP_RESERVE_BPS = 10; // 0.1%

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           STORAGE                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    uint256 private immutable _UNIT; // tokens per dino (see SCALE NOTE)

    address public immutable treasury;
    address public immutable router;

    address public mintContract; // set once by owner
    address public pair; // set once by mint contract at pool open
    address public quoteToken; // the pair's non-DPEG token (USDT); set with the pair
    address public renderer; // on-chain trait renderer, set once by owner

    bool public tradingEnabled; // flips ON at open; can never flip back
    uint256 public lastSwapBlock; // throttle for swapTaxToBnb (once per block)
    uint256 public lastBuybackBlock; // throttle for buybackAndBurn (once per block)

    /// @dev Tax accrued to the contract (in DPEG), split by destination. Both are held here until a
    ///      permissionless keeper call routes them out. No owner can touch these.
    uint256 public treasuryPool; // -> swapped to BNB -> treasury (buy 2.5% + sell 1%)
    uint256 public buybackPool; // -> real buyback+burn (sell 1.5%), direct-burn fallback

    /// @dev Addresses excluded from tax (mint contract, treasury, this contract).
    mapping(address => bool) public isTaxExempt;

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           ERRORS                            */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    error NotMintContract();
    error MintContractAlreadySet();
    error CapExceeded();
    error TradingNotOpen();
    error PairAlreadySet();
    error ZeroAddress();
    error RendererAlreadySet();
    error RendererNotSet();

    event RendererSet(address indexed renderer);
    event MintContractSet(address indexed mintContract);
    event PairSet(address indexed pair);
    event TradingEnabled();
    event TaxToTreasury(uint256 dpegIn, uint256 usdtOut);
    event BuybackAndBurn(uint256 tokenIn, uint256 burned, bool viaSwap);

    modifier onlyMintContract() {
        if (msg.sender != mintContract) revert NotMintContract();
        _;
    }

    /// @param treasury_ receives the 1%-accrued tax after it is swapped to BNB.
    /// @param router_   PancakeSwap V2 router used for the tax->BNB swap.
    /// @param unit_     tokens-per-dino (pass PROD_UNIT in production; see SCALE NOTE).
    constructor(address treasury_, address router_, uint256 unit_) {
        if (treasury_ == address(0) || router_ == address(0)) revert ZeroAddress();
        _initializeOwner(msg.sender);

        _UNIT = unit_;
        treasury = treasury_;
        router = router_;

        address mirror = address(new DN404Mirror(msg.sender));
        // Initial supply 0 — all tokens are minted by the mint contract.
        _initializeDN404(0, address(0), mirror);

        // Infra NFT-exclusions + tax-exemptions.
        isTaxExempt[address(this)] = true;
        isTaxExempt[treasury_] = true;
        _setSkipNFT(address(this), true);
        _setSkipNFT(treasury_, true);
        _setSkipNFT(router_, true);
        _setSkipNFT(DEAD, true);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         DN404 CONFIG                        */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function name() public pure override returns (string memory) {
        return _NAME;
    }

    function symbol() public pure override returns (string memory) {
        return _SYMBOL;
    }

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    function _unit() internal view override returns (uint256) {
        return _UNIT;
    }

    function unit() external view returns (uint256) {
        return _UNIT;
    }

    /// @dev Delegates to the on-chain DinoRenderer. The DN404 mirror's public tokenURI(id) routes
    ///      here via the base contract.
    function _tokenURI(uint256 id) internal view override returns (string memory) {
        address r = renderer;
        if (r == address(0)) revert RendererNotSet();
        return IDinoRenderer(r).tokenURI(id);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                       ADMIN (one-shot)                      */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Wires the on-chain trait renderer. One-shot (immutable in effect). After this the
    ///         owner may renounce; tokenURI is then fixed to this renderer forever.
    function setRenderer(address r) external onlyOwner {
        if (renderer != address(0)) revert RendererAlreadySet();
        if (r == address(0)) revert ZeroAddress();
        renderer = r;
        emit RendererSet(r);
    }

    /// @notice Wires the mint contract. One-shot. After this the owner may renounce.
    function setMintContract(address m) external onlyOwner {
        if (mintContract != address(0)) revert MintContractAlreadySet();
        if (m == address(0)) revert ZeroAddress();
        mintContract = m;
        isTaxExempt[m] = true;
        _setSkipNFT(m, true);
        emit MintContractSet(m);
    }

    /// @notice Registers the PancakeSwap pair (called by the mint contract at open). One-shot.
    function setPair(address p) external onlyMintContract {
        if (pair != address(0)) revert PairAlreadySet();
        if (p == address(0)) revert ZeroAddress();
        pair = p;
        // The pair's non-DPEG side is the quote asset (USDT) used for tax/buyback routing.
        address t0 = IPancakePair(p).token0();
        quoteToken = (t0 == address(this)) ? IPancakePair(p).token1() : t0;
        _setSkipNFT(p, true); // pool holds ERC20, never mints dinos
        emit PairSet(p);
    }

    /// @notice Opens trading. Only the mint contract, one-way (can never be turned off).
    function enableTrading() external onlyMintContract {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                            MINT                             */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Mint DPEG402. ONLY the mint contract. Reverts past the cap.
    /// @dev This is the ONLY way tokens are created. Owner cannot mint.
    function mint(address to, uint256 amount) external onlyMintContract {
        if (totalSupply() + amount > CAP) revert CapExceeded();
        _mint(to, amount);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                    TRANSFER / TAX OVERRIDE                   */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @dev Central transfer hook. Enforces the trading gate + ASYMMETRIC buy/sell tax.
    ///      Mint (`_mint`) and burn (`_burn`) do not route through here, so they always work.
    ///      BUY  (from==pair): 2.5% -> treasuryPool.
    ///      SELL (to==pair):   1% -> treasuryPool, 1.5% -> buybackPool.
    ///      Everything else (wallet-to-wallet, exempt infra): 0%.
    function _transfer(address from, address to, uint256 amount) internal override {
        // --- trading gate: before open, only the mint contract and this contract may move tokens.
        if (!tradingEnabled) {
            if (from != mintContract && to != mintContract && from != address(this)) {
                revert TradingNotOpen();
            }
        }

        bool withPair = pair != address(0) && (from == pair || to == pair)
            && !isTaxExempt[from] && !isTaxExempt[to];

        if (!withPair) {
            super._transfer(from, to, amount);
            return;
        }

        uint256 tax;
        if (from == pair) {
            // BUY: 2.5% -> treasury
            tax = (amount * BUY_TAX_BPS) / BPS;
            if (tax != 0) {
                treasuryPool += tax;
                super._transfer(from, address(this), tax);
            }
        } else {
            // SELL: 1% -> treasury, 1.5% -> buyback
            uint256 tre = (amount * SELL_TREASURY_BPS) / BPS;
            uint256 bb = (amount * SELL_BUYBACK_BPS) / BPS;
            tax = tre + bb;
            if (tax != 0) {
                treasuryPool += tre;
                buybackPool += bb;
                super._transfer(from, address(this), tax);
            }
        }
        super._transfer(from, to, amount - tax);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*               TAX ROUTING (permissionless, no owner)        */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Permissionless. Swaps up to 0.1% of the pool's DPEG reserve from the treasury pool to
    ///         USDT (the real DPEG/USDT pool) and forwards the USDT to the treasury. Once per block.
    /// @dev Routes through the ONLY pool that exists (DPEG/USDT) — no WETH/BNB leg. NO owner
    ///      withdraw; the only exit for treasuryPool is this swap-to-treasury path (anti-rug).
    ///      L1: if the quote reverts/is non-positive, skip (never a 0-floor swap); treasuryPool is
    ///      left intact and retried next block.
    function swapTaxToTreasury() external nonReentrant {
        require(tradingEnabled && pair != address(0), "not open");
        require(block.number > lastSwapBlock, "throttled");
        lastSwapBlock = block.number;

        uint256 amountIn = _capped(treasuryPool);
        if (amountIn == 0) return;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = quoteToken; // USDT

        uint256 amountOutMin = _minOut(path, amountIn);
        if (amountOutMin == 0) return;

        treasuryPool -= amountIn; // CEI: debit before external calls
        SafeTransferLib.safeApprove(address(this), router, amountIn);
        uint256 balBefore = _erc20BalanceOf(quoteToken, treasury);
        IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, amountOutMin, path, treasury, block.timestamp
        );
        emit TaxToTreasury(amountIn, _erc20BalanceOf(quoteToken, treasury) - balBefore);
    }

    /// @notice Permissionless buyback-and-burn of the accrued sell-tax (1.5%) buyback pool.
    ///         Post-open it performs a REAL market buyback against the DPEG/USDT pool: sell the
    ///         pool's DPEG for USDT, use that USDT to buy DPEG back, and burn the DPEG bought (real
    ///         buy pressure + deflation). If no pool yet, or either leg fails / lacks a valid quote,
    ///         it FALLS BACK to a direct burn so the value is never stuck or siphonable. Once/block.
    /// @dev Reentrancy-guarded; CEI (buybackPool debited before any external call); 95%-quote
    ///      slippage floor; no owner lever; the round-trip runs in a self-call so a failed leg rolls
    ///      back atomically and the fallback burn still fires.
    function buybackAndBurn() external nonReentrant {
        require(block.number > lastBuybackBlock, "throttled");
        lastBuybackBlock = block.number;

        uint256 amountIn =
            (tradingEnabled && pair != address(0)) ? _capped(buybackPool) : buybackPool;
        if (amountIn == 0) return;
        buybackPool -= amountIn; // CEI

        // Pre-open / no pool -> direct-burn fallback.
        if (!tradingEnabled || pair == address(0)) {
            _burn(address(this), amountIn);
            emit BuybackAndBurn(amountIn, amountIn, false);
            return;
        }

        try this.buybackSwap(amountIn) returns (uint256 burned) {
            emit BuybackAndBurn(amountIn, burned, true);
        } catch {
            // a swap leg failed -> state rolled back, amountIn DPEG still held here -> direct burn.
            _burn(address(this), amountIn);
            emit BuybackAndBurn(amountIn, amountIn, false);
        }
    }

    /// @dev Self-only atomic buyback leg: DPEG -> USDT -> DPEG, burn the DPEG bought. External so
    ///      the caller can try/catch for an atomic rollback-to-direct-burn. Reverts on any failure
    ///      or missing quote (L1: never a 0-floor swap).
    function buybackSwap(uint256 amountIn) external returns (uint256 burned) {
        require(msg.sender == address(this), "self only");
        address usdt = quoteToken;

        // leg 1: DPEG -> USDT (our own sell; from==this is tax-exempt, so no re-tax)
        address[] memory sellPath = new address[](2);
        sellPath[0] = address(this);
        sellPath[1] = usdt;
        uint256 sellMin = _minOut(sellPath, amountIn);
        require(sellMin != 0, "no quote");
        SafeTransferLib.safeApprove(address(this), router, amountIn);
        uint256 usdtBefore = _erc20BalanceOf(usdt, address(this));
        IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, sellMin, sellPath, address(this), block.timestamp
        );
        uint256 usdtGot = _erc20BalanceOf(usdt, address(this)) - usdtBefore;
        require(usdtGot != 0, "no usdt");

        // leg 2: USDT -> DPEG (the actual buyback; to==this is tax-exempt, received whole)
        address[] memory buyPath = new address[](2);
        buyPath[0] = usdt;
        buyPath[1] = address(this);
        uint256 buyMin = _minOut(buyPath, usdtGot);
        require(buyMin != 0, "no quote");
        SafeTransferLib.safeApprove(usdt, router, usdtGot);
        uint256 dpegBefore = balanceOf(address(this));
        IPancakeRouter(router).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            usdtGot, buyMin, buyPath, address(this), block.timestamp
        );
        burned = balanceOf(address(this)) - dpegBefore;
        require(burned != 0, "no buyback");
        _burn(address(this), burned);
    }

    function _erc20BalanceOf(address token, address who) internal view returns (uint256) {
        return SafeTransferLib.balanceOf(token, who);
    }

    /// @dev 0.1%-of-reserve-per-call cap, clamped to the contract's actual DPEG balance.
    function _capped(uint256 want) internal view returns (uint256) {
        uint256 cap = (_poolReserveDpeg() * SWAP_RESERVE_BPS) / BPS;
        uint256 amt = want < cap ? want : cap;
        uint256 bal = balanceOf(address(this));
        return amt < bal ? amt : bal;
    }

    /// @dev 95%-of-quote slippage floor; returns 0 if the quote reverts or is non-positive. Callers
    ///      MUST treat 0 as "no valid quote" and refuse to swap at a 0 floor (skip / direct-burn).
    function _minOut(address[] memory path, uint256 amountIn) internal view returns (uint256 m) {
        try IPancakeRouter(router).getAmountsOut(amountIn, path) returns (uint256[] memory outs) {
            if (outs.length >= 2) m = (outs[outs.length - 1] * 95) / 100;
        } catch {}
    }

    function _poolReserveDpeg() internal view returns (uint256) {
        IPancakePair p = IPancakePair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        return p.token0() == address(this) ? uint256(r0) : uint256(r1);
    }
}
