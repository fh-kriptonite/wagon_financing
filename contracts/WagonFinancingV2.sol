// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// @title: Wagon Network Financing
// @author: wagon.network
// @website: https://wagon.network
// @telegram: https://t.me/wagon_network

// ██╗    ██╗ █████╗  ██████╗  ██████╗ ███╗   ██╗
// ██║    ██║██╔══██╗██╔════╝ ██╔═══██╗████╗  ██║
// ██║ █╗ ██║███████║██║  ███╗██║   ██║██╔██╗ ██║
// ██║███╗██║██╔══██║██║   ██║██║   ██║██║╚██╗██║
// ╚███╔███╔╝██║  ██║╚██████╔╝╚██████╔╝██║ ╚████║
//  ╚══╝╚══╝ ╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═══╝

import "./IERC1155Mintable.sol";
import "./IERC20.sol";

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract WagonFinancingV2 is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeMathUpgradeable for uint256;
    using CountersUpgradeable for CountersUpgradeable.Counter;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    
    CountersUpgradeable.Counter private _counter;

    IERC1155Mintable private _erc1155Contract;

    address public feeAddress;

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
        uint256 status; // status: 1 = pool created ; 2 = pool start ; 3 = paid ; 4 = default ; 5 = disburse default ; 6 = pool canceled
        address borrower;
        uint256 latestRepayment;
    }

    struct ActivePool {
        uint256 collectedPrincipal;
        uint256 interestPerPayment;
        uint256 defaultAmountToDisburse;
    }

    uint256 public defaultBorrowerFee;
    uint256 public defaultAdminFee;
    uint256 public defaultProtocolFee;
    uint256 public defaultLateFee;
    uint256 public defaultLateDuration;
    uint256 public defaultGracePeriodDuration;

    struct Fee {
        uint256 borrowerFee; // bps
        uint256 adminFee; // bps
        uint256 protocolFee; // bps
        uint256 lateFee; // bps
        uint256 lateDuration; // seconds
        uint256 gracePeriodDuration; // seconds
    }

    // Mapping from token ID to its price
    mapping(uint256 => Pool)                        public pools;
    mapping(uint256 => Fee)                         public fees;
    mapping(uint256 => ActivePool)                  public activePools;
    
    // Mapping from pool ID to WAG locked mapping
    mapping(uint256 => mapping(address => uint256)) public wagLocked;
    mapping(uint256 => mapping(address => uint256)) public latestInterestClaimed;
    mapping(uint256 => mapping(address => bool))    public defaultClaimed;

    // lending statistic
    mapping(address => uint256)                     public totalValueLocked;
    mapping(address => uint256)                     public totalLoanOrigination;
    mapping(address => uint256)                     public currentLoansOutstanding;

    event PoolCreated(uint256 id, address indexed lendingCurrency);
    event UpdateFees(uint256 id);
    event PoolOpened(address indexed borrower, uint256 id, uint256 indexed targetLoan, uint256 indexed targetInterest);
    event TokenSold(address indexed buyer, uint256 indexed tokenId, uint256 price);
    event Lend(address indexed lender, uint256 indexed poolId, uint256 amount, uint256 pairingAmount);
    event UpdatecollectionTermEnd(uint256 indexed poolId, uint256 collectionTermEnd);
    event Borrow(uint256 indexed poolId, address indexed borrower, uint256 amount);
    event CancelPool(uint256 indexed poolId);
    event ClaimCancelPool(uint256 indexed poolId, uint256 amount);
    event Repayment(uint256 indexed poolId, address indexed borrower, uint256 amount);
    event ClaimInterest(uint256 indexed poolId, address indexed lender, uint256 amountInterest, uint256 amountPrincipal);
    event UpdateStatus(uint256 indexed poolId, uint256 status);
    event Default(uint256 indexed poolId, uint256 amount);
    event AddDefaultInsurance(uint256 indexed poolId, uint256 amount);
    event StartDisburseDefault(uint256 indexed poolId);
    event ClaimDefault(uint256 indexed poolId, address indexed lender, uint256 amount);

    function initialize(
        address erc1155ContractAddress
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _erc1155Contract = IERC1155Mintable(erc1155ContractAddress);
        feeAddress = msg.sender;

        defaultBorrowerFee = 20; // 0.20%
        defaultAdminFee = 20; // 0.20%
        defaultProtocolFee = 25; // 0.25%
        defaultLateFee = 10; // 0.1%
        defaultLateDuration = 86400; // 1 day
        defaultGracePeriodDuration = 259200; // 3 days

        // Assign the deployer the marketplace role
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    function updateFeeAddress(address _address) external onlyRole(ADMIN_ROLE) {
        feeAddress = _address;
    }

    function updateDefaultBorrowerFee(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultBorrowerFee = _value;
    }

    function updateDefaultAdminFee(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultAdminFee = _value;
    }

    function updateDefaultProtocolFee(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultProtocolFee = _value;
    }

    function updateDefaultLateFee(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultLateFee = _value;
    }

    function updateDefaultLateDuration(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultLateDuration = _value;
    }
    
    function updateDefaultGracePeriodDuration(uint256 _value) external onlyRole(ADMIN_ROLE) {
        defaultGracePeriodDuration = _value;
    }

    /**
     * @dev Create a lending pool and mint it's ERC1155.
     * @param _lendingCurrency Token address for the currency to use for lending
     * @param _pairingCurrency Token address for the pair currency to use for lending
     * @param _stabletoPairRate Rate how much pairing it should have compare to the main currency
     * @param _targetLoan The total target loan amount of the pool.
     * @param _targetInterestPerPayment Target Interest Per Payment.
     * @param _loanTerm Duration of loan in seconds
     * @param _collectionTermEnd End of collection timestamp
     * @param _paymentFrequency Payment count
     * @param _borrower Address of the borrower
     */
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
    ) external onlyRole(ADMIN_ROLE) {
        require(_targetLoan > 0, "targetLoan must be greater than zero");
        require(_targetInterestPerPayment > 0, "targetInterestPerPayment must be greater than zero");
        require(_loanTerm > 0, "loan term must be greater than zero");
        require(_collectionTermEnd > 0, "term start must be greater than zero");
        require(_paymentFrequency > 0, "payment frequency must be greater than zero");
        require(_borrower != address(0), "Borrower should not 0 address");

        // increase counter pool ID
        _counter.increment();
        uint256 _id = _counter.current();

        _erc1155Contract.setTokenMaxSupply(_id, _targetLoan);

        Pool storage pool = pools[_id];
        pool.lendingCurrency = IERC20(_lendingCurrency);
        pool.pairingCurrency = IERC20(_pairingCurrency);
        pool.stabletoPairRate = _stabletoPairRate;
        pool.targetLoan = _targetLoan;
        pool.targetInterestPerPayment = _targetInterestPerPayment;
        pool.loanTerm = _loanTerm;
        pool.collectionTermEnd = _collectionTermEnd;
        pool.paymentFrequency = _paymentFrequency;
        pool.borrower = _borrower;
        pool.status = 1;

        Fee storage fee = fees[_id];
        fee.borrowerFee = defaultBorrowerFee;
        fee.adminFee = defaultAdminFee;
        fee.protocolFee = defaultProtocolFee;
        fee.lateFee = defaultLateFee;
        fee.lateDuration = defaultLateDuration;
        fee.gracePeriodDuration = defaultGracePeriodDuration;

        emit PoolCreated(_id, _lendingCurrency);
    }

    /**
     * @dev Update a lending pool fees.
     * @param _poolId The ID of the pool to lend.
     * @param _borrowerFee Fee amount that will be cut from the loan
     * @param _adminFee Fee amount that will be cut when lend to pool
     * @param _protocolFee Fee amount that will be cut from the interest per term
     * @param _lateFee Fee amount that will be charge to borrower for late repayment
     * @param _lateDuration Late duration per term that will be charge to borrower for late repayment ex: 86400 (1 day)
     * @param _gracePeriodDuration grace duration that will be given to borrower for repayment ex: 86400 (1 day)
     */
    function updatePoolFees(
        uint256 _poolId,
        uint256 _borrowerFee, 
        uint256 _adminFee, 
        uint256 _protocolFee,
        uint256 _lateFee,
        uint256 _lateDuration,
        uint256 _gracePeriodDuration
    ) external onlyRole(ADMIN_ROLE) {
        require(pools[_poolId].status == 1, "Cannot update pool");

        Fee storage fee = fees[_poolId];
        fee.borrowerFee = _borrowerFee;
        fee.adminFee = _adminFee;
        fee.protocolFee = _protocolFee;
        fee.lateFee = _lateFee;
        fee.lateDuration = _lateDuration;
        fee.gracePeriodDuration = _gracePeriodDuration;

        emit UpdateFees(_poolId);
    }

    function getCurrentPoolId() external view returns (uint256) {
        return _counter.current();
    }

    /**
     * @dev Common logic for lending to pool and minting ERC1155 tokens.
     * @param poolId The ID of the pool to lend.
     * @param amount The amount of principal token to lend.
     * @param lender The address of the lender.
     */
    function _lendToPool(uint256 poolId, uint256 amount, address lender) private {
        // Access the struct at the specified address
        Pool storage pool = pools[poolId];
        Fee storage fee = fees[poolId];

        require(pool.status == 1, "Pool is not open for lend");
        require(block.timestamp <= pool.collectionTermEnd, "Pool term is ready to start");

        uint256 adminFee;
        uint256 pairAmount;
        uint256 totalAmount = amount;

        // calculate admin fee
        if(fee.adminFee > 0) {
            adminFee = amount.mul(fee.adminFee).div(10000);
            totalAmount = amount.add(adminFee);
        }

        // transfer from lender to lending contract
        pool.lendingCurrency.transferFrom(msg.sender, address(this), totalAmount);

        if (adminFee > 0) {
            pool.lendingCurrency.transfer(feeAddress, adminFee);
        }

        if(pool.stabletoPairRate > 0) {
            pairAmount = amount.mul(pool.stabletoPairRate).div(10**pool.lendingCurrency.decimals());
            pool.pairingCurrency.transferFrom(msg.sender, address(this), pairAmount);
            wagLocked[poolId][lender] = wagLocked[poolId][lender].add(pairAmount);
        }

        // Transfer the ERC1155 to the lender
        _erc1155Contract.mint(lender, poolId, amount, "");

        totalValueLocked[address(pool.lendingCurrency)] += amount;

        emit Lend(lender, poolId, amount, pairAmount);
    }

    /**
     * @dev Lent to pool and get ERC1155.
     * @param poolId The ID of the pool to lend.
     * @param amount The amount of principal token to lend.
     */
    function lendToPool(uint256 poolId, uint256 amount) external nonReentrant whenNotPaused {
        _lendToPool(poolId, amount, msg.sender);
    }

    /**
     * @dev Lent to pool on behalf of user and transfer ERC1155 to the user.
     * @param poolId The ID of the pool to lend.
     * @param amount The amount of principal token to lend.
     * @param onBehalfOf The address of the user on whose behalf the lending is done.
     */
    function lendToPoolOnBehalfOf(uint256 poolId, uint256 amount, address onBehalfOf) external nonReentrant whenNotPaused onlyRole(ADMIN_ROLE) {
        _lendToPool(poolId, amount, onBehalfOf);
    }

    /**
     * @dev Prolong the pool term for collection time.
     * @param poolId The ID of the pool to lend.
     * @param _collectionTermEnd The new collection end term timestamp.
     */
    function prolongPoolCollectionTime(uint256 poolId, uint256 _collectionTermEnd) external onlyRole(ADMIN_ROLE) {
        Pool storage pool = pools[poolId];

        require(pool.status == 1, "Pool is not open for lend");

        // Update the variable inside the struct
        pool.collectionTermEnd = _collectionTermEnd;

        emit UpdatecollectionTermEnd(poolId, _collectionTermEnd);
    }

    /**
     * @dev Withdraw collected amount to borrower address and start the lending
     * @param poolId The ID of the pool to lend.
     */
    function borrow(uint256 poolId) external nonReentrant whenNotPaused{
        Pool storage pool = pools[poolId];
        Fee storage fee = fees[poolId];

        require(pool.status == 1, "Pool is not open for lend");

        // Update pool status to start lending
        pool.status = 2;
        pool.termStart = block.timestamp;

        uint256 collectedPrincipal = _erc1155Contract.tokenSupply(poolId);
        uint256 borrowMoney = collectedPrincipal;

        activePools[poolId].collectedPrincipal = collectedPrincipal;

        uint256 interestPerPayment = pool.targetInterestPerPayment;

        if(collectedPrincipal < pool.targetLoan) {
            interestPerPayment = collectedPrincipal.mul(pool.targetInterestPerPayment).div(pool.targetLoan);
        }

        activePools[poolId].interestPerPayment = interestPerPayment;

        if(fee.borrowerFee > 0) {
            uint256 borrowFee = pool.targetLoan.mul(fee.borrowerFee).div(10000);
            require(borrowFee <= borrowMoney, "Borrow fee exceeds borrow amount");
        
            borrowMoney -= borrowFee;
            pool.lendingCurrency.transfer(feeAddress, borrowFee);
        }

        pool.lendingCurrency.transfer(pool.borrower, borrowMoney);

        totalLoanOrigination[address(pool.lendingCurrency)] += collectedPrincipal;

        uint256 totalInterest = interestPerPayment.mul(pool.paymentFrequency);
        currentLoansOutstanding[address(pool.lendingCurrency)] += collectedPrincipal.add(totalInterest);

        emit Borrow(poolId, pool.borrower, borrowMoney);
    }

    /**
     * @dev Cancel pool if it's not fulfilled and the borrower dont want to continue. Let lender claim their deposits.
     * @param poolId The ID of the pool to lend.
     */
    function cancelPool(uint256 poolId) external onlyRole(ADMIN_ROLE) {
        Pool storage pool = pools[poolId];

        require(pool.status == 1, "Pool is not open for lend");
        
        pool.status = 6;

        emit CancelPool(poolId);
    }

    /**
     * @dev Claim cancel pooled
     * @param poolId The ID of the pool to lend.
     * @param onBehalfOf user address to claim.
     */
    function claimCancelPool(uint256 poolId, address onBehalfOf) external nonReentrant() {
        Pool storage pool = pools[poolId];

        require(pool.status == 6, "Pool is not canceled");

        uint256 shares = _erc1155Contract.balanceOf(onBehalfOf, poolId);

        require(shares > 0, "User dont have any share for this pool");
        
        _erc1155Contract.burn(onBehalfOf, poolId, shares);

        pool.lendingCurrency.transfer(onBehalfOf, shares);
        pool.pairingCurrency.transfer(onBehalfOf, wagLocked[poolId][onBehalfOf]);

        totalValueLocked[address(pool.lendingCurrency)] -= shares;
        
        emit ClaimCancelPool(poolId, shares);
    }

    function durationPerTerm(uint256 loanTerm, uint256 paymentFrequency) public pure returns (uint256) {
        return loanTerm.div(paymentFrequency);
    }

    function getCurrentTermWithGracePeriod(uint256 termStart, uint256 loanTerm, uint256 paymentFrequency, uint256 latestRepayment, uint256 gracePeriod) public view returns (uint256) {
        uint256 _durationPerTerm = durationPerTerm(loanTerm, paymentFrequency); // 1000

        uint256 elapsedTime = block.timestamp > (termStart + gracePeriod) 
            ? block.timestamp - termStart - gracePeriod // 1724777525 - 1724773090 - 600 = 3835
            : 0;

        uint256 currentTerm = elapsedTime / _durationPerTerm + 1; // 3835 / 1000 + 1 = 4

        if(currentTerm > paymentFrequency) currentTerm = paymentFrequency;

        return currentTerm > latestRepayment ? currentTerm : latestRepayment;
    }

    function calculateLateFee(uint256 poolId, uint256 loanTerm, uint256 termStart, uint256 latestRepayment, uint256 paymentFrequency) internal view returns (uint256) {
        if(latestRepayment == paymentFrequency) return 0;
        uint256 _durationPerTerm = durationPerTerm(loanTerm, paymentFrequency);

        uint256 latestDeadlineTimestamp = termStart.add(latestRepayment.add(1).mul(_durationPerTerm)).add(fees[poolId].gracePeriodDuration);

        if (block.timestamp <= latestDeadlineTimestamp) return 0;

        uint256 lateDuration = block.timestamp - latestDeadlineTimestamp;

        uint256 lateFeePerTerm = activePools[poolId].interestPerPayment.mul(fees[poolId].lateFee).div(10000);
        uint256 numberOfLateTerm = lateDuration.div(fees[poolId].lateDuration).add(1);
        
        return numberOfLateTerm.mul(lateFeePerTerm);
    }

    function calculateAmountToRepay(uint256 poolId, uint256 currentTerm) internal view returns (uint256 interestPayment, uint256 principalPayment, uint256 latePayment) {
        Pool storage pool = pools[poolId];

        uint256 termCountToPay = currentTerm.sub(pool.latestRepayment); // 2
        interestPayment = activePools[poolId].interestPerPayment.mul(termCountToPay); // 2000

        if (currentTerm == pool.paymentFrequency) {
            principalPayment = activePools[poolId].collectedPrincipal;
        }

        latePayment = calculateLateFee(poolId, pool.loanTerm, pool.termStart, pool.latestRepayment, pool.paymentFrequency);

        return (interestPayment, principalPayment, latePayment);
    }

    /**
     * @dev Calculate the amount required to repay for a specific pool.
     * @param poolId The ID of the pool for which the repayment amount is to be calculated.
     * @return The amount to be repaid for the given pool ID.
     */
    function getAmountToRepay(uint256 poolId) public view returns (uint256) {
        Pool storage pool = pools[poolId];

        uint256 currentTerm = getCurrentTermWithGracePeriod(pool.termStart, pool.loanTerm, pool.paymentFrequency, pool.latestRepayment, fees[poolId].gracePeriodDuration);

        (uint256 interestPayment, uint256 principalPayment, uint256 latePayment) = calculateAmountToRepay(poolId, currentTerm);

        return interestPayment.add(principalPayment).add(latePayment);
    }

    function _applyProtocolFee(uint256 poolId, Pool storage pool, uint256 interestShares) internal returns (uint256) {
        if (fees[poolId].protocolFee > 0) {
            uint256 protocolFee = interestShares.mul(fees[poolId].protocolFee).div(10000);
            pool.lendingCurrency.transfer(feeAddress, protocolFee);
            return interestShares.sub(protocolFee);
        }
        return interestShares;
    }

    /**
     * @dev Repay the outstanding loan amount for a specific pool.
     * @param poolId The ID of the pool for which the loan repayment is being made.
     */
    function repay(uint256 poolId) external nonReentrant whenNotPaused{
        Pool storage pool = pools[poolId];

        require(pool.status == 2, "Pool is not active");

        uint256 currentTerm = getCurrentTermWithGracePeriod(pool.termStart, pool.loanTerm, pool.paymentFrequency, pool.latestRepayment, fees[poolId].gracePeriodDuration);
        
        (uint256 interestPayment, uint256 principalPayment, uint256 latePayment) = calculateAmountToRepay(poolId, currentTerm);
        
        uint256 amountToRepay = interestPayment.add(principalPayment);

        require(amountToRepay > 0, "Nothing to pay");

        pool.lendingCurrency.transferFrom(msg.sender, address(this), amountToRepay);

        if (latePayment > 0) {
            pool.lendingCurrency.transferFrom(msg.sender, feeAddress, latePayment);
        }

        uint256 netInterest = _applyProtocolFee(poolId, pool, interestPayment);

        pool.latestRepayment = currentTerm;

        if (currentTerm == pool.paymentFrequency) {
            pool.status = 3;
        }
        
        address lendingCurrencyAddress = address(pool.lendingCurrency);
        totalValueLocked[lendingCurrencyAddress] += netInterest;
        currentLoansOutstanding[lendingCurrencyAddress] -= amountToRepay;

        emit Repayment(poolId, msg.sender, amountToRepay);
    }

    /**
     * @dev Calculate the amount of interest shares held by a user for a specific pool.
     * @param poolId The ID of the pool for which the interest shares are being queried.
     * @param _address The address of the user whose interest shares are being calculated.
     * @return The amount of interest shares held by the specified user for the given pool.
     */
    function getInterestAmountShare(uint256 poolId, address _address) public view returns (uint256) {
        uint256 totalShares = activePools[poolId].collectedPrincipal;
        if(totalShares == 0) return 0;

        uint256 shares = _erc1155Contract.balanceOf(_address, poolId);
        if(shares == 0) return 0;
        
        return shares.mul(activePools[poolId].interestPerPayment).div(totalShares);
    }

    /**
     * @dev Get the amount of principal shares held by a user for a specific pool.
     * @param poolId The ID of the pool for which the principal shares are being queried.
     * @param _address The address of the user whose principal shares are being retrieved.
     * @return The amount of principal shares held by the specified user for the given pool.
     */
    function getPrincipalAmountShare(uint256 poolId, address _address) public view returns (uint256) {
        return _erc1155Contract.balanceOf(_address, poolId);
    }

    function _calculateClaimableShares(uint256 poolId, address _address) internal view returns (uint256 interestShares, uint256 principalShares) {
        Pool storage pool = pools[poolId];

        uint256 shares = _erc1155Contract.balanceOf(_address, poolId);
        uint256 totalShares = activePools[poolId].collectedPrincipal;
        uint256 totalInterest = activePools[poolId].interestPerPayment.mul(pool.latestRepayment.sub(latestInterestClaimed[poolId][_address]));
        interestShares = shares.mul(totalInterest).div(totalShares);

        principalShares = (pool.latestRepayment == pool.paymentFrequency) ? shares : 0;
        return (interestShares, principalShares);
    }

    /**
     * @dev Calculate the claimable interest amount for a user.
     * @param poolId The ID of the pool for which interest is being claimed.
     * @param _address The address of the user whose claimable interest amount is being calculated.
     * @return The total claimable amount, which includes both interest and principal shares.
     */
    function getClaimableInterestAmount(uint256 poolId, address _address) external view returns (uint256) {
        Pool storage pool = pools[poolId];
        uint256 latestClaimed = latestInterestClaimed[poolId][_address];
    
        if(latestClaimed >= pool.paymentFrequency) return 0;
        if(latestClaimed >= pool.latestRepayment) return 0;

        (uint256 interestShares, uint256 principalShares) = _calculateClaimableShares(poolId, _address);
        return interestShares.add(principalShares);
    }

    function _applyProtocolFee(uint256 poolId, uint256 interestShares) internal view returns (uint256) {
        if (fees[poolId].protocolFee > 0) {
            uint256 protocolFee = interestShares.mul(fees[poolId].protocolFee).div(10000);
            return interestShares.sub(protocolFee);
        }
        return interestShares;
    }

    /**
     * @dev Allows a user to claim their interest from a lending pool.
     * @param poolId The ID of the pool from which interest is being claimed.
     * @param onBehalfOf The address of the user claiming the interest.
     */
    function claimInterest(uint256 poolId, address onBehalfOf) external nonReentrant whenNotPaused {
        Pool storage pool = pools[poolId];
        uint256 latestClaimed = latestInterestClaimed[poolId][onBehalfOf];
        uint256 paymentFreq = pool.paymentFrequency;
        uint256 latestRepayment = pool.latestRepayment;

        require(latestClaimed < paymentFreq, "All interest has been claimed");
        require(latestClaimed < latestRepayment, "No interest to be claimed");

        (uint256 interestShares, uint256 principalShares) = _calculateClaimableShares(poolId, onBehalfOf);

        require(interestShares > 0, "User dont have any interest shares");

        // Apply protocol fee
        interestShares = _applyProtocolFee(poolId, interestShares);

        uint256 wagAmount = wagLocked[poolId][onBehalfOf];
        if (principalShares > 0) {
            _erc1155Contract.burn(onBehalfOf, poolId, principalShares);
            if (wagAmount > 0) {
                pool.pairingCurrency.transfer(onBehalfOf, wagAmount);
                wagLocked[poolId][onBehalfOf] = 0;
            }
        }

        latestInterestClaimed[poolId][onBehalfOf] = latestRepayment;

        uint256 amountToClaim = interestShares.add(principalShares);
        pool.lendingCurrency.transfer(onBehalfOf, amountToClaim);

        totalValueLocked[address(pool.lendingCurrency)] -= amountToClaim;

        emit ClaimInterest(poolId, onBehalfOf, interestShares, principalShares);
    }

    /**
     * @dev Allows a user to claim their interest from a lending pool before transfer.
     * @param poolId The ID of the pool from which interest is being claimed.
     * @param onBehalfOf The address of the user claiming the interest.
     */
    function claimInterestBeforeTransfer(uint256 poolId, address onBehalfOf) external nonReentrant whenNotPaused {
        Pool storage pool = pools[poolId];
        uint256 latestClaimed = latestInterestClaimed[poolId][onBehalfOf];
        uint256 paymentFreq = pool.paymentFrequency;
        uint256 latestRepayment = pool.latestRepayment;

        if(latestClaimed >= paymentFreq) return;
        if(latestClaimed >= latestRepayment) return;

        (uint256 interestShares, uint256 principalShares) = _calculateClaimableShares(poolId, onBehalfOf);

        if(interestShares == 0) return;

        // Apply protocol fee
        interestShares = _applyProtocolFee(poolId, interestShares);

        uint256 wagAmount = wagLocked[poolId][onBehalfOf];
        if (principalShares > 0) {
            _erc1155Contract.burn(onBehalfOf, poolId, principalShares);
            if (wagAmount > 0) {
                pool.pairingCurrency.transfer(onBehalfOf, wagAmount);
                wagLocked[poolId][onBehalfOf] = 0;
            }
        }

        latestInterestClaimed[poolId][onBehalfOf] = latestRepayment;

        uint256 amountToClaim = interestShares.add(principalShares);
        pool.lendingCurrency.transfer(onBehalfOf, amountToClaim);

        totalValueLocked[address(pool.lendingCurrency)] -= amountToClaim;

        emit ClaimInterest(poolId, onBehalfOf, interestShares, principalShares);
    }

    function isRepaid(uint256 poolId) external view returns (bool) {
        Pool storage pool = pools[poolId];
        return (pool.latestRepayment == pool.paymentFrequency);
    }

    /**
     * @dev Set pool status into any status.
     * @param poolId The ID of the pool to lend.
     * @param status Status ID, status: 1 = pool created; 2 = pool start; 3 = paid; 4 = default; 5 = disburse default; 6 = pool canceled;
     */
    function setPoolStatus(uint256 poolId, uint256 status) external onlyRole(ADMIN_ROLE) {
        pools[poolId].status = status;

        emit UpdateStatus(poolId, status);
    }

    /**
     * @dev Calculates the total unpaid interest for a given pool.
     * @param poolId The ID of the pool for which to calculate the unpaid interest.
     * @return The total amount of unpaid interest for the specified pool.
     */
    function calculateUnpaidInterest(uint256 poolId) public view returns (uint256) {
        Pool storage pool = pools[poolId];

        uint256 unpaidTermsCount = pool.paymentFrequency - pool.latestRepayment;
        return activePools[poolId].interestPerPayment.mul(unpaidTermsCount);
    }

    /**
     * @dev Set pool status to default and add amount to be disburse.
     * @param poolId The ID of the pool to lend.
     * @param amount The number of amount to be disburse.
     * @param defaultVault The address that will add the amount.
     */
    function setPoolDefault(uint256 poolId, uint256 amount, address defaultVault) external onlyRole(ADMIN_ROLE) {
        Pool storage pool = pools[poolId];
        ActivePool storage activePool = activePools[poolId];

        require(pool.status != 4, "Pool is already in default status");
        
        pool.status = 4;
        
        if(amount > 0) {
            pool.lendingCurrency.transferFrom(defaultVault, address(this), amount);
            activePool.defaultAmountToDisburse += amount;
        }

        uint256 collectedPrincipal = activePool.collectedPrincipal;
        uint256 unpaidInterest = calculateUnpaidInterest(poolId);

        totalValueLocked[address(pool.lendingCurrency)] -= collectedPrincipal.sub(amount);

        currentLoansOutstanding[address(pool.lendingCurrency)] -= unpaidInterest.add(collectedPrincipal);

        emit Default(poolId, amount);
    }

    /**
     * @dev Add amount to be disbursed in the default pool.
     * @param poolId The ID of the pool to lend.
     * @param amount The number of amount to be disburse.
     * @param defaultVault The address that will add the amount.
     */
    function addDefaultForDisburse(uint256 poolId, uint256 amount, address defaultVault) external onlyRole(ADMIN_ROLE) {
        Pool storage pool = pools[poolId];
        ActivePool storage activePool = activePools[poolId];

        require(pool.status == 4, "Pool is not in default");
        require(amount > 0, "Nothing to add");

        pool.lendingCurrency.transferFrom(defaultVault, address(this), amount);
        activePool.defaultAmountToDisburse += amount;

        address currency = address(pool.lendingCurrency);
        totalValueLocked[currency] += amount;
        
        emit AddDefaultInsurance(poolId, amount);
    }

    /**
     * @dev Allow users to start claiming from default pool.
     * @param poolId The ID of the pool to claim.
     */
    function startPoolDefaultDisburse(uint256 poolId) external onlyRole(ADMIN_ROLE) {
        require(pools[poolId].status == 4, "Pool is not in default");

        pools[poolId].status = 5;

        emit StartDisburseDefault(poolId);
    }

    /**
     * @dev Claim the default value from a defaulted pool on behalf of a user.
     * @param poolId The ID of the pool to claim from.
     * @param onBehalfOf The user address to claim for.
     */
    function claimDefault(uint256 poolId, address onBehalfOf) external nonReentrant whenNotPaused {
        Pool storage pool = pools[poolId];
        require(pool.status == 5, "Pool default is not ready to be disburse");
        require(!defaultClaimed[poolId][onBehalfOf], "Claimed already");

        uint256 shares = _erc1155Contract.balanceOf(onBehalfOf, poolId);
        uint256 totalShares = activePools[poolId].collectedPrincipal;
        uint256 defaultAmount = activePools[poolId].defaultAmountToDisburse;

        uint256 userDefaultShare = shares.mul(defaultAmount).div(totalShares);

        defaultClaimed[poolId][onBehalfOf] = true;
        _erc1155Contract.burn(onBehalfOf, poolId, shares);

        pool.lendingCurrency.transfer(onBehalfOf, userDefaultShare);

        totalValueLocked[address(pool.lendingCurrency)] -= userDefaultShare;

        emit ClaimDefault(poolId, onBehalfOf, userDefaultShare);
    }

    /**
     * @dev Emergency withdraw
     * @param _address ERC20 address
     * @param amount Amount to be withdraw
     */
    function withdrawErc20(address _address, uint256 amount) public nonReentrant onlyRole(ADMIN_ROLE) {
        require(amount > 0, "Amount to transfer is 0");
        require(_address != address(0), "Address cannot be zero");
        IERC20 erc20 = IERC20(_address);
        erc20.transfer(msg.sender, amount);
    }
}