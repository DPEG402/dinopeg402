// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DinoRenderer} from "../src/DinoRenderer.sol";
import {DinoPeg402} from "../src/DinoPeg402.sol";
import {DinoMint} from "../src/DinoMint.sol";

/// @notice DinoPeg402 launch deploy. Dry-run now (no --broadcast); broadcast at launch.
/// @dev Keys/addresses come ONLY from the environment via vm.env* — never hardcoded, never logged.
///      Run (dry-run):   forge script script/Deploy.s.sol --rpc-url $BSC
///      Run (broadcast): forge script script/Deploy.s.sol --rpc-url $BSC --broadcast
///      Env required: DEPLOYER_PK (uint), TREASURY (address), BACKEND_SIGNER (address).
contract Deploy is Script {
    // Real BSC mainnet addresses.
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    function run() external returns (DinoRenderer renderer, DinoPeg402 token, DinoMint mint) {
        // Keys/addresses from env ONLY (keep keys in chmod600 files outside the repo):
        //   export DEPLOYER_PK=$(cat ./secrets/deployer.key)
        //   export BACKEND_SIGNER_PK=$(cat ./secrets/signer.key)   # optional (else BACKEND_SIGNER addr)
        //   export TREASURY=0x...   BACKEND_SIGNER=0x...
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address treasury = vm.envAddress("TREASURY");
        // The contract only needs the signer ADDRESS (it verifies vouchers against it). Prefer
        // deriving it from BACKEND_SIGNER_PK when present; else take the BACKEND_SIGNER address.
        uint256 signerPk = vm.envOr("BACKEND_SIGNER_PK", uint256(0));
        address backendSigner =
            signerPk != 0 ? vm.addr(signerPk) : vm.envAddress("BACKEND_SIGNER");
        uint256 unit = DinoPeg402Const.PROD_UNIT();

        vm.startBroadcast(pk);

        // 1) Renderer — writes the packed trait blob to SSTORE2 in its constructor.
        renderer = new DinoRenderer();

        // 2) Token — decimals=9, UNIT=50M*1e9, CAP=444T*1e9 (constant). Deployer is owner.
        token = new DinoPeg402(treasury, ROUTER, unit);

        // 3) Mint — holds all the fair-mint / anti-rug logic.
        mint = new DinoMint(
            address(token), treasury, backendSigner, REGISTRY, USDT, FACTORY, ROUTER
        );

        // 4) Wire. setRenderer + setMintContract are one-shot; the latter also marks the mint
        //    tax-exempt + skipNFT. The token ctor already excluded self/treasury/router/dead;
        //    the pair is registered + excluded by the mint contract at open().
        token.setRenderer(address(renderer));
        token.setMintContract(address(mint));
        // Both setters are one-shot; renounce so owner()==0 (fully trustless, BscScan shows 0).
        // Nothing after wiring needs the owner — trading/pair are mint-contract-gated.
        token.renounceOwnership();

        vm.stopBroadcast();

        _summary(renderer, token, mint, treasury, backendSigner);
    }

    function _summary(
        DinoRenderer renderer,
        DinoPeg402 token,
        DinoMint mint,
        address treasury,
        address backendSigner
    ) internal view {
        console.log("=====================================================");
        console.log("DinoPeg402 deploy summary (chainId 56 / BNB Smart Chain)");
        console.log("-----------------------------------------------------");
        console.log("DinoRenderer :", address(renderer));
        console.log("  blobPointer:", renderer.blobPointer());
        console.log("DinoPeg402   :", address(token));
        console.log("  decimals   :", token.decimals());
        console.log("  unit       :", token.unit());
        console.log("  CAP        :", token.CAP());
        console.log("DinoMint     :", address(mint));
        console.log("USDT         :", USDT);
        console.log("Registry     :", REGISTRY);
        console.log("Factory      :", FACTORY);
        console.log("Router       :", ROUTER);
        console.log("Treasury     :", treasury);
        console.log("BackendSigner:", backendSigner);
        console.log("-----------------------------------------------------");
        console.log("Next: verify on BscScan, then set backend/config.json:");
        console.log('  "tokenAddr": <DinoPeg402>, "mintAddr": <DinoMint>,');
        console.log('  "signer": <BackendSigner>, "deployed": true');
        console.log("=====================================================");
    }
}

/// @dev Tiny helper so the script reads the token's canonical UNIT without re-declaring magic.
library DinoPeg402Const {
    function PROD_UNIT() internal pure returns (uint256) {
        return 50_000_000 * 1e9; // = token PROD_UNIT (decimals=9)
    }
}
