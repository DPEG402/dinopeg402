// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Minimal interfaces for external systems DinoPeg402 integrates with.

/// @dev BNB .ai Agent-ID registry (ERC721-style ownerOf).
interface IAgentRegistry {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @dev PancakeSwap V2 factory.
interface IPancakeFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/// @dev PancakeSwap V2 router (subset).
interface IPancakeRouter {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts);
}

/// @dev PancakeSwap V2 pair (subset).
interface IPancakePair {
    function getReserves()
        external
        view
        returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    /// @dev Low-level LP mint: mints LP to `to` for whatever was transferred in since last sync.
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

/// @dev Uniswap Permit2 SignatureTransfer (the piece the x402 facilitator relays).
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }

    /// @notice Transfers a token using a signed permit message.
    /// @param permit The permit data signed over by the owner.
    /// @param transferDetails The spender's requested transfer details for the permitted token.
    /// @param owner The owner of the tokens to transfer.
    /// @param signature The signature to verify.
    function permitTransferFrom(
        PermitTransferFrom calldata permit,
        SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}
