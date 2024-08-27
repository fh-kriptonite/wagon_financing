// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./IERC1155Mintable.sol";
import "./IERC20.sol";

interface IWagonFinancingV2 {
    struct Pool {
        IERC20 lendingCurrency;
        IERC20 pairingCurrency;
        uint256 stabletoPairRate;
        uint256 targetLoan;
        uint256 targetInterestPerPayment;
        uint256 loanTerm;
        uint256 collectionTermEnd;
        uint256 termStart;
        uint256 paymentFrequency;
        uint256 status;
        address borrower;
        uint256 latestRepayment;
    }

    struct ActivePool {
        uint256 collectedPrincipal;
        uint256 interestPerPayment;
        uint256 defaultAmountToDisburse;
    }

    struct Fee {
        uint256 borrowerFee;
        uint256 adminFee;
        uint256 protocolFee;
        uint256 lateFee;
        uint256 lateDuration;
        uint256 gracePeriodDuration;
    }

    // Initialization
    function initialize(address erc1155ContractAddress) external;

    // Fee Management
    function updateFeeAddress(address _address) external;
    function updateDefaultBorrowerFee(uint256 _value) external;
    function updateDefaultAdminFee(uint256 _value) external;
    function updateDefaultProtocolFee(uint256 _value) external;
    function updateDefaultLateFee(uint256 _value) external;
    function updateDefaultLateDuration(uint256 _value) external;
    function updateDefaultGracePeriodDuration(uint256 _value) external;

    // Pool Management
    function createLendingPool(
        address _lendingCurrency, 
        address _pairingCurrency,
        uint256 _stabletoPairRate, 
        uint256 _targetLoan, 
        uint256 _targetInterestPerPayment, 
        uint256 _loanTerm,
        uint256 _collectionTermEnd, 
        uint256 _paymentFrequency, 
        address _borrower
    ) external;

    function updatePoolFees(
        uint256 _poolId,
        uint256 _borrowerFee, 
        uint256 _adminFee, 
        uint256 _protocolFee,
        uint256 _lateFee,
        uint256 _lateDuration,
        uint256 _gracePeriodDuration
    ) external;

    function prolongPoolCollectionTime(uint256 poolId, uint256 _collectionTermEnd) external;
    function cancelPool(uint256 poolId) external;
    function claimCancelPool(uint256 poolId, address onBehalfOf) external;
    function setPoolStatus(uint256 poolId, uint256 status) external;
    function setPoolDefault(uint256 poolId, uint256 amount, address defaultVault) external;
    function addDefaultForDisburse(uint256 poolId, uint256 amount, address defaultVault) external;
    function startPoolDefaultDisburse(uint256 poolId) external;
    function claimDefault(uint256 poolId, address onBehalfOf) external;
    function withdrawErc20(address _address, uint256 amount) external;

    // Pool Query
    function getCurrentPoolId() external view returns (uint256);
    function durationPerTerm(uint256 loanTerm, uint256 paymentFrequency) external pure returns (uint256);
    function getCurrentTermWithGracePeriod(uint256 termStart, uint256 loanTerm, uint256 paymentFrequency, uint256 latestRepayment, uint256 gracePeriod) external view returns(uint256);
    function calculateLateFee(uint256 poolId, uint256 loanTerm, uint256 termStart, uint256 latestRepayment, uint256 paymentFrequency) external view returns (uint256);
    function getAmountToRepay(uint256 poolId) external view returns (uint256);
    function isRepaid(uint256 poolId) external view returns (bool);
    function getInterestAmountShare(uint256 poolId, address _address) external view returns (uint256);
    function getPrincipalAmountShare(uint256 poolId, address _address) external view returns (uint256);
    function getClaimableInterestAmount(uint256 poolId, address _address) external view returns (uint256);

    // Transactions
    function lendToPool(uint256 poolId, uint256 amount, address onBehalfOf) external;
    function lendToPoolOnBehalfOf(uint256 poolId, uint256 amount, address onBehalfOf, address lender) external;
    function borrow(uint256 poolId, address onBehalfOf) external;
    function repay(uint256 poolId, address onBehalfOf) external;
    function claimInterest(uint256 poolId, address onBehalfOf) external;
    function claimInterestBeforeTransfer(uint256 poolId, address onBehalfOf) external;
}
