// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title RFRM NFT
 * @notice A contract for Reform NFT Collection
 * @author Reform DAO
 */

import { ERC721Enumerable, ERC721 } from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract RFRMNFT is ERC721Enumerable, Ownable, ReentrancyGuard {
    // ----- Token config -----
    // Total number of NFT that can be minted
    uint256 public immutable maxSupply;
    // Current number of tokens
    uint256 public numTokens = 0;

    event NFTMinted(uint256 number, address recipient);

    error MaxSupplyExceeded();

    // Constructor. We set the symbol and name and start with sa
    constructor(uint256 _maxSupply) ERC721("NFTToken", "NFT") {
        maxSupply = _maxSupply;
    }

    /// @notice Mint a number of tokens and send them to sender
    /// @param _number How many tokens to mint
    /// @param _recipient Receiver of NFT
    function mint(uint256 _number, address _recipient) external nonReentrant onlyOwner {
        uint256 supply = uint256(totalSupply());
        if (supply + _number > maxSupply) revert MaxSupplyExceeded();

        uint256 tokenID;
        for (uint256 i; i < _number; i++) {
            tokenID = numTokens;
            numTokens++;
            _safeMint(_recipient, tokenID);
        }

        emit NFTMinted(_number, _recipient);
    }

    // ----- Helper functions -----
    /// @notice Get all token ids belonging to an address
    /// @param _owner Wallet to find tokens of
    /// @return  Array of the owned token ids
    function walletOfOwner(address _owner) external view returns (uint256[] memory) {
        uint256 tokenCount = balanceOf(_owner);

        uint256[] memory tokensId = new uint256[](tokenCount);
        for (uint256 i; i < tokenCount; i++) {
            tokensId[i] = tokenOfOwnerByIndex(_owner, i);
        }
        return tokensId;
    }
}
