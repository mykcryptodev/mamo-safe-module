// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IMamoStrategy} from "./interfaces/IMamoStrategy.sol";
import {IMToken} from "./interfaces/IMToken.sol";
import {IERC4626Minimal} from "./interfaces/IERC4626Minimal.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {ISafe} from "./interfaces/ISafe.sol";

contract PawthereumMamoYieldModule is ReentrancyGuard {
    struct Recipient {
        address addr;
        uint16 bps;
    }

    struct Preview {
        uint256 strategyValue;
        uint256 safeIdle;
        uint256 totalYield;
        uint256 totalDistributed;
        uint256 compoundedAmount;
        uint256[] amounts;
        bool canExecute;
    }

    address public immutable SAFE;
    address public immutable MAMO_STRATEGY;
    address public immutable USDC;
    address public immutable M_TOKEN;
    address public immutable META_MORPHO_VAULT;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_RECIPIENTS = 16;

    Recipient[] private _recipients;
    uint256 public protectedPrincipal;
    uint256 public lastExecutionTimestamp;
    uint256 public executionInterval;
    uint256 public minimumClaimAmount;
    bool public paused;

    error ZeroAddress();
    error ZeroBps();
    error BpsOverflow();
    error DuplicateRecipient();
    error TooManyRecipients();
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
        uint256 totalDistributed,
        uint256 compoundedAmount,
        uint256 newProtectedPrincipal
    );
    event YieldDistributed(address indexed recipient, uint256 amount);
    event RecipientsUpdated(Recipient[] recipients, uint16 compoundBps);
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
        Recipient[] memory initialRecipients,
        uint256 protectedPrincipal_,
        uint256 executionInterval_,
        uint256 minimumClaimAmount_
    ) {
        if (
            safe_ == address(0) || mamoStrategy_ == address(0) || usdc_ == address(0) || mToken_ == address(0)
                || metaMorphoVault_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (executionInterval_ == 0) revert InvalidExecutionInterval();

        SAFE = safe_;
        MAMO_STRATEGY = mamoStrategy_;
        USDC = usdc_;
        M_TOKEN = mToken_;
        META_MORPHO_VAULT = metaMorphoVault_;

        protectedPrincipal = protectedPrincipal_;
        executionInterval = executionInterval_;
        minimumClaimAmount = minimumClaimAmount_;

        _setRecipients(initialRecipients);
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

    function getRecipients() external view returns (Recipient[] memory) {
        return _recipients;
    }

    function getRecipient(uint256 index) external view returns (address addr, uint16 bps) {
        Recipient storage r = _recipients[index];
        return (r.addr, r.bps);
    }

    function recipientCount() external view returns (uint256) {
        return _recipients.length;
    }

    function getDistribution() external view returns (Recipient[] memory recipients, uint16 compoundBps) {
        recipients = _recipients;
        uint256 sumBps;
        for (uint256 i; i < recipients.length; ++i) {
            sumBps += recipients[i].bps;
        }
        compoundBps = uint16(BPS - sumBps);
    }

    function executeYieldCapture()
        external
        nonReentrant
        returns (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 totalDistributed,
            uint256 compoundedAmount
        )
    {
        if (paused) revert IsPaused();
        if (block.timestamp < lastExecutionTimestamp + executionInterval) revert TooEarly();

        strategyValueBefore = getStrategyValue();
        uint256 safeIdleBefore = getSafeUSDC();

        if (strategyValueBefore + safeIdleBefore <= protectedPrincipal) revert NoYield();
        totalYield = strategyValueBefore + safeIdleBefore - protectedPrincipal;

        uint256[] memory amounts;
        (amounts, totalDistributed) = _computeAmounts(totalYield);

        if (_recipients.length > 0 && totalDistributed == 0) revert BelowMinimum();
        if (totalDistributed < minimumClaimAmount) revert BelowMinimum();

        if (totalDistributed > 0) {
            _safeExec(MAMO_STRATEGY, abi.encodeCall(IMamoStrategy.withdraw, (totalDistributed)));
            if (getSafeUSDC() < safeIdleBefore + totalDistributed) revert WithdrawFailed();
            _payRecipients(amounts);
        }

        compoundedAmount = totalYield - totalDistributed;
        protectedPrincipal += compoundedAmount;
        if (getStrategyValue() + getSafeUSDC() < protectedPrincipal) revert PrincipalViolation();

        lastExecutionTimestamp = block.timestamp;

        emit YieldExecuted(strategyValueBefore, totalYield, totalDistributed, compoundedAmount, protectedPrincipal);
    }

    function previewYieldCapture() external returns (Preview memory p) {
        p.strategyValue = getStrategyValue();
        p.safeIdle = getSafeUSDC();
        if (p.strategyValue + p.safeIdle > protectedPrincipal) {
            p.totalYield = p.strategyValue + p.safeIdle - protectedPrincipal;
        }
        (p.amounts, p.totalDistributed) = _computeAmounts(p.totalYield);
        p.compoundedAmount = p.totalYield - p.totalDistributed;
        p.canExecute = !paused && block.timestamp >= lastExecutionTimestamp + executionInterval
            && p.totalYield > 0 && p.totalDistributed >= minimumClaimAmount
            && (_recipients.length == 0 || p.totalDistributed > 0);
    }

    function _computeAmounts(uint256 totalYield)
        internal
        view
        returns (uint256[] memory amounts, uint256 totalDistributed)
    {
        uint256 n = _recipients.length;
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 amt = (totalYield * _recipients[i].bps) / BPS;
            amounts[i] = amt;
            totalDistributed += amt;
        }
    }

    function _payRecipients(uint256[] memory amounts) internal {
        uint256 n = amounts.length;
        for (uint256 i; i < n; ++i) {
            uint256 amt = amounts[i];
            if (amt > 0) {
                address to = _recipients[i].addr;
                _safeExec(USDC, abi.encodeCall(IERC20Minimal.transfer, (to, amt)));
                emit YieldDistributed(to, amt);
            }
        }
    }

    function setRecipients(Recipient[] calldata newRecipients) external onlySafe {
        _setRecipients(newRecipients);
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

    function _setRecipients(Recipient[] memory newRecipients) internal {
        uint256 n = newRecipients.length;
        if (n > MAX_RECIPIENTS) revert TooManyRecipients();

        uint256 sumBps;
        for (uint256 i; i < n; ++i) {
            Recipient memory r = newRecipients[i];
            if (r.addr == address(0)) revert ZeroAddress();
            if (r.bps == 0) revert ZeroBps();
            for (uint256 j; j < i; ++j) {
                if (newRecipients[j].addr == r.addr) revert DuplicateRecipient();
            }
            sumBps += r.bps;
        }
        if (sumBps > BPS) revert BpsOverflow();

        delete _recipients;
        for (uint256 i; i < n; ++i) {
            _recipients.push(newRecipients[i]);
        }

        emit RecipientsUpdated(newRecipients, uint16(BPS - sumBps));
    }

    function _safeExec(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) =
            ISafe(SAFE).execTransactionFromModuleReturnData(to, 0, data, ISafe.Operation.Call);
        if (!ok) revert SafeCallFailed();
        if (ret.length != 0 && !abi.decode(ret, (bool))) revert SafeCallFailed();
    }
}
