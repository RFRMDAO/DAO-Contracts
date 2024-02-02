// SPDX-License-Identifier: MIT

/// @title RFRM Token
/// @notice The token contract of Reform DAO with the Burnable extension.
/// @dev This token has a total supply of 1 Billion with 18 decimal places.
/// @author Reform DAO

pragma solidity 0.8.23;

// Import the necessary OpenZeppelin contracts
import { ERC20, ERC20Burnable } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

// Define the RFRM token contract
contract RFRM is ERC20Burnable {
    /// @dev Constructor function to initialize the token
    constructor() ERC20("Reform", "$RFRM") {
        // Mint 1 Billion tokens and assign them to the contract creator
        _mint(msg.sender, 1_000_000_000 * 10 ** decimals());
    }
}
