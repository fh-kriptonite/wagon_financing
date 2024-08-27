// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "./IWagonFinancingV2.sol";

contract WagonFinancingERC1155V2 is ERC1155Upgradeable, AccessControlUpgradeable {
    // Base URI for metadata
    string private _baseTokenURI;

    // Mapping from token ID to its supply
    mapping(uint256 => uint256) public tokenSupply;
    mapping(uint256 => uint256) public tokenMaxSupply;

    // Role to mint tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    // Status to activate transferable for minter only
    bool public transferableMinterOnly;

    // Address of the deployed WagonFinancingV2 contract
    IWagonFinancingV2 public wagonFinancingV2;

    // Event emitted when a new token is minted
    event Minted(address indexed account, uint256 indexed tokenId, uint256 amount);
    event MintedBatch(address indexed account, uint256[] indexed tokenIds, uint256[] amounts);
    
    // Event emitted when a token is burned
    event Burned(address indexed account, uint256 indexed tokenId, uint256 amount);
    event BurnedBatch(address indexed account, uint256[] indexed tokenIds, uint256[] amounts);

    function initialize(string memory _uri) public initializer {
        __ERC1155_init(_uri);
        __AccessControl_init();

        _baseTokenURI = _uri;

        // Assign the deployer the default admin role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(MINTER_ROLE, msg.sender);
        transferableMinterOnly = true;
    }

    /**
     * @dev Supports ERC165 interface.
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /**
     * @dev Sets the base URI for all token IDs.
     * @param baseTokenURI The base URI to set.
     */
    function setBaseTokenURI(string memory baseTokenURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(baseTokenURI);
    }

    /**
     * @dev Sets the maximum token supply for the token ID.
     * @param tokenId The ID of the token to be set.
     * @param maxSupply The maximum supply.
     */
    function setTokenMaxSupply(uint256 tokenId, uint256 maxSupply) external onlyRole(MINTER_ROLE) {
        tokenMaxSupply[tokenId] = maxSupply;
    }

    /**
     * @dev Mint a new batch of tokens.
     * @param account The address that will receive the minted tokens.
     * @param tokenId The ID of the token to mint.
     * @param amount The amount of tokens to mint.
     * @param data Additional data with no specified format.
     */
    function mint(address account, uint256 tokenId, uint256 amount, bytes memory data) external onlyRole(MINTER_ROLE) {
        require(tokenSupply[tokenId] + amount <= tokenMaxSupply[tokenId], "Surpassing maximum supply");
        _mint(account, tokenId, amount, data);
        tokenSupply[tokenId] += amount;
        emit Minted(account, tokenId, amount);
    }

    /**
     * @dev Mint batch of new batches of tokens.
     * @param account The address that will receive the minted tokens.
     * @param tokenIds The ID of the token to mint.
     * @param amounts The amount of tokens to mint.
     * @param data Additional data with no specified format.
     */
    function mintBatch(address account, uint256[] memory tokenIds, uint256[] memory amounts, bytes memory data) external onlyRole(MINTER_ROLE) {
        _mintBatch(account, tokenIds, amounts, data);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            tokenSupply[tokenIds[i]] += amounts[i];
        }
        emit MintedBatch(account, tokenIds, amounts);
    }

    /**
     * @dev Burn a batch of tokens.
     * @param account The address that will burn the tokens.
     * @param tokenId The ID of the token to burn.
     * @param amount The amount of tokens to burn.
     */
    function burn(address account, uint256 tokenId, uint256 amount) external onlyRole(MINTER_ROLE) {
        _burn(account, tokenId, amount);
        emit Burned(account, tokenId, amount);
    }

    /**
     * @dev Burn batch of batches of tokens.
     * @param account The address that will burn the tokens.
     * @param tokenIds The ID of the token to burn.
     * @param amounts The amount of tokens to burn.
     */
    function burnBatch(address account, uint256[] memory tokenIds, uint256[] memory amounts) external onlyRole(MINTER_ROLE) {
        _burnBatch(account, tokenIds, amounts);
        emit BurnedBatch(account, tokenIds, amounts);
    }

    /**
     * @dev See {IERC1155MetadataURI-uri}.
     * @param tokenId The ID of the token.
     * @return The URI for the token.
     */
    function uri(uint256 tokenId) public view override returns (string memory) {
        return string(abi.encodePacked(super.uri(tokenId), StringsUpgradeable.toString(tokenId)));
    }

    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        if(transferableMinterOnly) {
            require(hasRole(MINTER_ROLE, from) || hasRole(MINTER_ROLE, to) || from == address(0) || to == address(0), "Sender or receiver must have MINTER_ROLE or 0 address");
        } else if(!(from == address(0) || to == address(0))) {
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 poolId = ids[i];

                require(!wagonFinancingV2.isRepaid(poolId), "Cannot transfer NFT after matured");

                // Claim interest before transferring tokens
                wagonFinancingV2.claimInterestBeforeTransfer(poolId, from);
                wagonFinancingV2.claimInterestBeforeTransfer(poolId, to);
            }
        }
    }

    /**
     * @dev Toggle transferable minter only variable.
     */
    function toggleTransferableMinterOnly() external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferableMinterOnly = !transferableMinterOnly;
    }

    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal override {
        super._afterTokenTransfer(operator, from, to, ids, amounts, data);

        if(to == address(0)) {
            for(uint256 i = 0; i < ids.length; i++) {
                uint256 id = ids[i];
                uint256 amount = amounts[i];

                tokenSupply[id] -= amount;
            }
        }
    }

    function setWagonFinancingAddress(address _wagonFinancingV2Address) external onlyRole(DEFAULT_ADMIN_ROLE){
        wagonFinancingV2 = IWagonFinancingV2(_wagonFinancingV2Address);
    }
}
