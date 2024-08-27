// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/**
 * @dev Interface for the ERC-1155 token standard.
 */
interface IERC1155Mintable is IERC1155{
    
    /**
     * @dev Get the total supply of the token
     * @param tokenId The ID of the token to check.
     */
    function tokenSupply(uint256 tokenId) external view returns (uint256);

    /**
     * @dev Sets the maximum token supply for the token ID.
     * @param tokenId The ID of the token to be set.
     * @param maxSupply The maximum supply.
     */
    function setTokenMaxSupply(uint256 tokenId, uint256 maxSupply) external;

    /** 
     * @dev Mint a new batch of tokens.
     * @param account The address that will receive the minted tokens.
     * @param tokenId The ID of the token to mint.
     * @param amount The amount of tokens to mint.
     * @param data Additional data with no specified format.
     */
    function mint(address account, uint256 tokenId, uint256 amount, bytes memory data) external;
    
    /**
     * @dev Emitted when a new token is minted.
     */
    event Minted(address indexed operator, address indexed to, uint256 id, uint256 value, bytes data);

    /**
     * @dev Burn a batch of tokens.
     * @param account The address that will burn the tokens.
     * @param tokenId The ID of the token to burn.
     * @param amount The amount of tokens to burn.
     */
    function burn(address account, uint256 tokenId, uint256 amount) external;
 
    /**
     * @dev Emitted when an existing token is burned.
     */
    event Burn(address indexed operator, address indexed from, uint256 id, uint256 value);
}
