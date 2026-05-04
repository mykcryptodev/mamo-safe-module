// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IMamoStrategy} from "./interfaces/IMamoStrategy.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IERC4626Minimal} from "./interfaces/IERC4626Minimal.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {ISafe} from "./interfaces/ISafe.sol";

contract PawthereumMamoYieldModule is ReentrancyGuard {
    address public immutable SAFE;
    address public immutable MAMO_STRATEGY;
    address public immutable USDC;
    address public immutable M_TOKEN;
    address public immutable META_MORPHO_VAULT;

    uint256 public constant BPS = 10_000;
    uint256 public constant CLAIM_BPS = 9_000;
    uint256 public constant DONATION_SPLIT_BPS = 5_000;
    uint256 public constant DEV_SPLIT_BPS = 5_000;

    address public donationRecipient;
    address public devRecipient;
    uint256 public protectedPrincipal;
    uint256 public lastExecutionTimestamp;
    uint256 public executionInterval;
    uint256 public minimumClaimAmount;
    bool public paused;

    error ZeroAddress();
    error NotSafe();
    error IsPaused();
    error TooEarly();
    error NoYield();
    error BelowMinimum();
    error WithdrawFailed();
    error PrincipalViolation();
    error SafeCallFailed();
    error InvalidExecutionInterval();

    event YieldExecuted(
        uint256 strategyValueBefore,
        uint256 totalYield,
        uint256 claimedYield,
        uint256 donationAmount,
        uint256 devAmount,
        uint256 newProtectedPrincipal
    );
    event DonationRecipientUpdated(address indexed previous, address indexed current);
    event DevRecipientUpdated(address indexed previous, address indexed current);
    event ProtectedPrincipalUpdated(uint256 previous, uint256 current);
    event ExecutionIntervalUpdated(uint256 previous, uint256 current);
    event MinimumClaimAmountUpdated(uint256 previous, uint256 current);
    event PausedSet(bool paused);

    modifier onlySafe() {
        if (msg.sender != SAFE) revert NotSafe();
        _;
    }

    constructor(
        address safe_,
        address mamoStrategy_,
        address usdc_,
        address mToken_,
        address metaMorphoVault_,
        address donationRecipient_,
        address devRecipient_,
        uint256 protectedPrincipal_,
        uint256 executionInterval_,
        uint256 minimumClaimAmount_
    ) {
        if (
            safe_ == address(0) || mamoStrategy_ == address(0) || usdc_ == address(0) || mToken_ == address(0)
                || metaMorphoVault_ == address(0) || donationRecipient_ == address(0) || devRecipient_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (executionInterval_ == 0) revert InvalidExecutionInterval();

        SAFE = safe_;
        MAMO_STRATEGY = mamoStrategy_;
        USDC = usdc_;
        M_TOKEN = mToken_;
        META_MORPHO_VAULT = metaMorphoVault_;

        donationRecipient = donationRecipient_;
        devRecipient = devRecipient_;
        protectedPrincipal = protectedPrincipal_;
        executionInterval = executionInterval_;
        minimumClaimAmount = minimumClaimAmount_;
    }

    function getStrategyValue() public returns (uint256) {
        uint256 morphoShares = IERC4626Minimal(META_MORPHO_VAULT).balanceOf(MAMO_STRATEGY);
        uint256 morphoAssets = morphoShares == 0 ? 0 : IERC4626Minimal(META_MORPHO_VAULT).convertToAssets(morphoShares);
        uint256 moonwellAssets = IMToken(M_TOKEN).balanceOfUnderlying(MAMO_STRATEGY);
        uint256 idleUsdc = IERC20Minimal(USDC).balanceOf(MAMO_STRATEGY);
        return morphoAssets + moonwellAssets + idleUsdc;
    }

    function getSafeUSDC() public view returns (uint256) {
        return IERC20Minimal(USDC).balanceOf(SAFE);
    }

    function executeYieldCapture()
        external
        nonReentrant
        returns (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount
        )
    {
        if (paused) revert IsPaused();
        if (block.timestamp < lastExecutionTimestamp + executionInterval) revert TooEarly();

        strategyValueBefore = getStrategyValue();
        uint256 safeIdleBefore = getSafeUSDC();
        uint256 totalAssets = strategyValueBefore + safeIdleBefore;

        if (totalAssets <= protectedPrincipal) revert NoYield();
        totalYield = totalAssets - protectedPrincipal;

        claimedYield = (totalYield * CLAIM_BPS) / BPS;
        if (claimedYield < minimumClaimAmount) revert BelowMinimum();

        devAmount = (claimedYield * DEV_SPLIT_BPS) / BPS;
        donationAmount = claimedYield - devAmount;

        _safeExec(MAMO_STRATEGY, abi.encodeCall(IMamoStrategy.withdraw, (claimedYield)));

        if (getSafeUSDC() < safeIdleBefore + claimedYield) revert WithdrawFailed();

        _safeExec(USDC, abi.encodeCall(IERC20Minimal.transfer, (donationRecipient, donationAmount)));
        _safeExec(USDC, abi.encodeCall(IERC20Minimal.transfer, (devRecipient, devAmount)));

        uint256 newPrincipal = protectedPrincipal + (totalYield - claimedYield);
        if (getStrategyValue() + getSafeUSDC() < newPrincipal) revert PrincipalViolation();
        protectedPrincipal = newPrincipal;

        lastExecutionTimestamp = block.timestamp;

        emit YieldExecuted(strategyValueBefore, totalYield, claimedYield, donationAmount, devAmount, newPrincipal);
    }

    function previewYieldCapture()
        external
        returns (
            uint256 strategyValue,
            uint256 safeIdle,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount,
            bool canExecute
        )
    {
        strategyValue = getStrategyValue();
        safeIdle = getSafeUSDC();
        uint256 totalAssets = strategyValue + safeIdle;

        if (totalAssets > protectedPrincipal) {
            totalYield = totalAssets - protectedPrincipal;
            claimedYield = (totalYield * CLAIM_BPS) / BPS;
            devAmount = (claimedYield * DEV_SPLIT_BPS) / BPS;
            donationAmount = claimedYield - devAmount;
        }

        canExecute = !paused && block.timestamp >= lastExecutionTimestamp + executionInterval
            && claimedYield >= minimumClaimAmount;
    }

    function setDonationRecipient(address newRecipient) external onlySafe {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit DonationRecipientUpdated(donationRecipient, newRecipient);
        donationRecipient = newRecipient;
    }

    function setDevRecipient(address newRecipient) external onlySafe {
        if (newRecipient == address(0)) revert ZeroAddress();
        emit DevRecipientUpdated(devRecipient, newRecipient);
        devRecipient = newRecipient;
    }

    function setProtectedPrincipal(uint256 newPrincipal) external onlySafe {
        emit ProtectedPrincipalUpdated(protectedPrincipal, newPrincipal);
        protectedPrincipal = newPrincipal;
    }

    function setExecutionInterval(uint256 newInterval) external onlySafe {
        if (newInterval == 0) revert InvalidExecutionInterval();
        emit ExecutionIntervalUpdated(executionInterval, newInterval);
        executionInterval = newInterval;
    }

    function setMinimumClaimAmount(uint256 newMinimum) external onlySafe {
        emit MinimumClaimAmountUpdated(minimumClaimAmount, newMinimum);
        minimumClaimAmount = newMinimum;
    }

    function pause() external onlySafe {
        paused = true;
        emit PausedSet(true);
    }

    function unpause() external onlySafe {
        paused = false;
        emit PausedSet(false);
    }

    function _safeExec(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) =
            ISafe(SAFE).execTransactionFromModuleReturnData(to, 0, data, ISafe.Operation.Call);
        if (!ok) revert SafeCallFailed();
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert SafeCallFailed();
    }
}
