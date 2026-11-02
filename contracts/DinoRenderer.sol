// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {SSTORE2} from "solady/utils/SSTORE2.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";
import {DinoTraitData} from "./DinoTraitData.sol";

/// @title DinoRenderer
/// @notice Fully on-chain, layered generative trait renderer for DinoPeg402. The packed trait
///         blob (generated from web/traits.json, see scratchpad/gen_traits.py) is stored via
///         SSTORE2 at deploy and composited at read time. Logic mirrors the website reference
///         renderer (tgrid/pickW/dinoTraits/renderTraitDino) so on-chain output matches the
///         preview distribution: same weights, same pick order, same Body-Color remap.
/// @dev Layer ids follow the canonical weight-table order baked into DinoTraitData.
contract DinoRenderer {
    using LibString for uint256;

    uint256 internal constant N = 100; // 100x100 grid
    uint256 internal constant NONE = 255; // sentinel: no accessory / no feature

    /// @dev SSTORE2 pointer to the packed trait blob (≈8KB → single pointer).
    address public immutable blobPointer;

    constructor() {
        blobPointer = SSTORE2.write(DinoTraitData.blob());
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         TRAIT PICK                          */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Weighted trait pick from `seed`. Pick order: Background, Feature, Accessory, Color.
    ///         Each pick hashes a successive word of the seed. Returns layer ids (NONE for an
    ///         absent feature/accessory) and the color-variant index (0=Gold..6=Pink).
    function traitsOf(uint256 seed)
        public
        pure
        returns (uint8 bgId, uint8 ftId, uint8 acId, uint8 colVariant)
    {
        bgId = uint8(_pickBg(_word(seed, 0)));
        ftId = uint8(_pickFt(_word(seed, 1)));
        acId = uint8(_pickAc(_word(seed, 2)));
        colVariant = uint8(_pickCol(_word(seed, 3)));
    }

    function _word(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// @dev Generic weighted pick: returns ids[k] where the word lands in the cumulative weights.
    function _pick(uint256 word, uint256[] memory ids, uint256[] memory w)
        internal
        pure
        returns (uint256)
    {
        uint256 total;
        for (uint256 i; i < w.length; ++i) total += w[i];
        uint256 x = word % total;
        for (uint256 i; i < w.length; ++i) {
            if (x < w[i]) return ids[i];
            x -= w[i];
        }
        return ids[ids.length - 1];
    }

    // Background: Desert 100, Dunes 100, Cactus 40, Cactus1 40, Cactus2 40, Cactus3 40, Meteors 12, Plane 4
    function _pickBg(uint256 word) internal pure returns (uint256) {
        uint256[] memory ids = new uint256[](8);
        uint256[] memory w = new uint256[](8);
        for (uint256 i; i < 8; ++i) ids[i] = i; // layer ids 0..7
        w[0] = 100; w[1] = 100; w[2] = 40; w[3] = 40; w[4] = 40; w[5] = 40; w[6] = 12; w[7] = 4;
        return _pick(word, ids, w);
    }

    // Feature: None 60, Freckles 100, Pattern 100, Spikes 40, Horns 40, Back 40, Sticks 40, Bone 12, Canop 12, Fire 4
    function _pickFt(uint256 word) internal pure returns (uint256) {
        uint256[] memory ids = new uint256[](10);
        uint256[] memory w = new uint256[](10);
        ids[0] = NONE;
        for (uint256 i = 1; i < 10; ++i) ids[i] = 8 + i; // layer ids 9..17
        w[0] = 60; w[1] = 100; w[2] = 100; w[3] = 40; w[4] = 40;
        w[5] = 40; w[6] = 40; w[7] = 12; w[8] = 12; w[9] = 4;
        return _pick(word, ids, w);
    }

    // Accessory: None 50, Cap 100, Hat 100, Glasses 40, Headphone 40, Mask 40, Mill hat 40,
    //            Smoking 12, Steam 12, Stars 12, Fleck 12, Water 12, Fire 12, Halo 4, Laser 4
    function _pickAc(uint256 word) internal pure returns (uint256) {
        uint256[] memory ids = new uint256[](15);
        uint256[] memory w = new uint256[](15);
        ids[0] = NONE;
        for (uint256 i = 1; i < 15; ++i) ids[i] = 17 + i; // layer ids 18..31
        w[0] = 50; w[1] = 100; w[2] = 100; w[3] = 40; w[4] = 40; w[5] = 40; w[6] = 40; w[7] = 12;
        w[8] = 12; w[9] = 12; w[10] = 12; w[11] = 12; w[12] = 12; w[13] = 4; w[14] = 4;
        return _pick(word, ids, w);
    }

    // Color: Gold 100, Green 40, Blue 40, Purple 20, Red 20, Mint 14, Pink 10
    function _pickCol(uint256 word) internal pure returns (uint256) {
        uint256[] memory ids = new uint256[](7);
        uint256[] memory w = new uint256[](7);
        for (uint256 i; i < 7; ++i) ids[i] = i; // variant 0..6
        w[0] = 100; w[1] = 40; w[2] = 40; w[3] = 20; w[4] = 20; w[5] = 14; w[6] = 10;
        return _pick(word, ids, w);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                         COMPOSITE                           */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Composite SVG for the given traits, in layer order Background -> Base -> Accessory
    ///         -> Feature (topmost non-transparent wins). Body-Color remap applies ONLY to Base +
    ///         Feature layers. Horizontal runs of equal color are merged per row.
    function renderSVG(uint8 bgId, uint8 ftId, uint8 acId, uint8 colVariant)
        public
        view
        returns (string memory)
    {
        bytes memory data = SSTORE2.read(blobPointer);

        bytes memory idxArr = new bytes(N * N); // palette index per cell (0 = transparent)
        bytes memory bodyArr = new bytes(N * N); // 1 if the winning layer is Base/Feature

        _paint(data, bgId, false, idxArr, bodyArr); // Background
        _paint(data, 8, true, idxArr, bodyArr); // Base/Main base
        if (acId != NONE) _paint(data, acId, false, idxArr, bodyArr); // Accessory
        if (ftId != NONE) _paint(data, ftId, true, idxArr, bodyArr); // Feature

        string memory svg =
            '<svg viewBox="0 0 100 100" shape-rendering="crispEdges" xmlns="http://www.w3.org/2000/svg">';

        for (uint256 y; y < N; ++y) {
            string memory row = "";
            uint256 x;
            while (x < N) {
                uint256 code = _code(idxArr, bodyArr, y * N + x, colVariant);
                if (code == 0) {
                    ++x;
                    continue;
                }
                uint256 x0 = x;
                while (x < N && _code(idxArr, bodyArr, y * N + x, colVariant) == code) ++x;
                row = string.concat(
                    row,
                    '<rect x="', x0.toString(),
                    '" y="', y.toString(),
                    '" width="', (x - x0).toString(),
                    '" height="1" fill="', _hexOf(code, colVariant), '"/>'
                );
            }
            svg = string.concat(svg, row);
        }
        return string.concat(svg, "</svg>");
    }

    /// @dev Decode one layer's RLE from the blob and paint it onto the composite (overwriting).
    function _paint(bytes memory data, uint256 layerId, bool isBody, bytes memory idxArr, bytes memory bodyArr)
        internal
        pure
    {
        (uint256 off, uint256 len) = DinoTraitData.layerSlice(layerId);
        uint256 end = off + len;
        uint256 cur;
        bytes1 b = isBody ? bytes1(uint8(1)) : bytes1(uint8(0));
        for (uint256 p = off; p < end; p += 3) {
            uint8 idx = uint8(data[p]);
            uint256 run = (uint256(uint8(data[p + 1])) << 8) | uint256(uint8(data[p + 2]));
            if (idx != 0) {
                for (uint256 c; c < run; ++c) {
                    idxArr[cur + c] = bytes1(idx);
                    bodyArr[cur + c] = b;
                }
            }
            cur += run;
        }
    }

    /// @dev Merge key for a cell: 0 = transparent, 1..8 = palette index, 100+idx = remapped body.
    function _code(bytes memory idxArr, bytes memory bodyArr, uint256 j, uint8 colVariant)
        internal
        pure
        returns (uint256)
    {
        uint256 idx = uint8(idxArr[j]);
        if (idx == 0) return 0;
        if (bodyArr[j] != 0 && colVariant != 0 && (idx == 2 || idx == 4 || idx == 7)) {
            return 100 + idx;
        }
        return idx;
    }

    function _hexOf(uint256 code, uint8 colVariant) internal pure returns (string memory) {
        if (code >= 100) return _remapHex(colVariant, code - 100);
        return DinoTraitData.paletteHex(code);
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                   BODY-COLOR REMAP TABLE                    */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    // idx is one of {2,4,7}; colVariant 1..6 (Gold=0 never reaches here).
    function _remapHex(uint8 colVariant, uint256 idx) internal pure returns (string memory) {
        if (colVariant == 1) { // Green
            if (idx == 2) return "#4fbf52";
            if (idx == 4) return "#2f8a37";
            return "#9fe060";
        }
        if (colVariant == 2) { // Blue
            if (idx == 2) return "#3ea0f0";
            if (idx == 4) return "#2866b0";
            return "#8fd4ff";
        }
        if (colVariant == 3) { // Purple
            if (idx == 2) return "#a46cf0";
            if (idx == 4) return "#6d3fb0";
            return "#caa0ff";
        }
        if (colVariant == 4) { // Red
            if (idx == 2) return "#f0533b";
            if (idx == 4) return "#b02e25";
            return "#ff9080";
        }
        if (colVariant == 5) { // Mint
            if (idx == 2) return "#3fd0b0";
            if (idx == 4) return "#2a9080";
            return "#8ff0d8";
        }
        // colVariant == 6 Pink
        if (idx == 2) return "#fb7ab0";
        if (idx == 4) return "#c04878";
        return "#ffb2d6";
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                           NAMES                             */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    function _colName(uint8 v) internal pure returns (string memory) {
        if (v == 0) return "Gold";
        if (v == 1) return "Green";
        if (v == 2) return "Blue";
        if (v == 3) return "Purple";
        if (v == 4) return "Red";
        if (v == 5) return "Mint";
        return "Pink";
    }

    function _layerName(uint256 id) internal pure returns (string memory) {
        // Background
        if (id == 0) return "Desert";
        if (id == 1) return "Dunes";
        if (id == 2) return "Cactus";
        if (id == 3) return "Cactus 1";
        if (id == 4) return "Cactus 2";
        if (id == 5) return "Cactus 3";
        if (id == 6) return "Meteors";
        if (id == 7) return "Plane";
        // Base
        if (id == 8) return "Main base";
        // Features
        if (id == 9) return "Freckles";
        if (id == 10) return "Pattern";
        if (id == 11) return "Spikes";
        if (id == 12) return "Horns";
        if (id == 13) return "Back";
        if (id == 14) return "Sticks";
        if (id == 15) return "Bone";
        if (id == 16) return "Canop";
        if (id == 17) return "Fire";
        // Accessories
        if (id == 18) return "Cap";
        if (id == 19) return "Hat";
        if (id == 20) return "Glasses";
        if (id == 21) return "Headphone";
        if (id == 22) return "Mask";
        if (id == 23) return "Mill hat";
        if (id == 24) return "Smoking";
        if (id == 25) return "Steam";
        if (id == 26) return "Stars";
        if (id == 27) return "Fleck";
        if (id == 28) return "Water";
        if (id == 29) return "Fire";
        if (id == 30) return "Halo";
        return "Laser"; // 31
    }

    /*«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-«-*/
    /*                          TOKEN URI                          */
    /*-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»-»*/

    /// @notice Deterministic per-tokenId metadata. seed = keccak256(abi.encode(tokenId)).
    /// @dev A block salt could be mixed at mint for block-derived entropy, but seeding from the
    ///      tokenId keeps the art re-derivable forever — which suits DN404 id recycling (an id
    ///      that is burned and later re-minted renders identically).
    function tokenURI(uint256 tokenId) external view returns (string memory) {
        uint256 seed = uint256(keccak256(abi.encode(tokenId)));
        (uint8 bgId, uint8 ftId, uint8 acId, uint8 colVariant) = traitsOf(seed);

        string memory image = string.concat(
            "data:image/svg+xml;base64,", Base64.encode(bytes(renderSVG(bgId, ftId, acId, colVariant)))
        );

        string memory attrs = string.concat(
            '[{"trait_type":"Background","value":"', _layerName(bgId), '"},',
            '{"trait_type":"Body","value":"', _colName(colVariant), '"},',
            '{"trait_type":"Accessory","value":"', acId == NONE ? "None" : _layerName(acId), '"},',
            '{"trait_type":"Feature","value":"', ftId == NONE ? "None" : _layerName(ftId), '"}]'
        );

        string memory json = string.concat(
            '{"name":"DinoPeg402 #', tokenId.toString(),
            '","description":"DinoPeg402 ($DPEG402) liquid-collectible dinos, rendered fully on-chain.",',
            '"image":"', image, '","attributes":', attrs, "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}
