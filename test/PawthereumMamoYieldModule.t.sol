// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PawthereumMamoYieldModule} from "../src/PawthereumMamoYieldModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";
import {IERC4626Minimal} from "../src/interfaces/IERC4626Minimal.sol";
import {IMToken} from "../src/interfaces/IMToken.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockMToken {
    mapping(address => uint256) internal _balance;

    function balanceOfUnderlying(address owner) external returns (uint256) {
        return _balance[owner];
    }

    function set(address owner, uint256 amount) external {
        _balance[owner] = amount;
    }
}

contract MockMorphoVault {
    mapping(address => uint256) internal _shares;
    uint256 public rate = 1e18;

    function balanceOf(address owner) external view returns (uint256) {
        return _shares[owner];
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return (shares * rate) / 1e18;
    }

    function setShares(address owner, uint256 shares) external {
        _shares[owner] = shares;
    }

    function setRate(uint256 newRate) external {
        rate = newRate;
    }
}

contract MockMamoStrategy {
    MockERC20 public immutable usdc;
    int256 public shortfall;
    bool public shouldRevert;

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function withdraw(uint256 amount) external {
        if (shouldRevert) revert("MAMO_WITHDRAW_REVERTED");
        uint256 toSend = uint256(int256(amount) - shortfall);
        usdc.transfer(msg.sender, toSend);
    }

    function setShortfall(int256 v) external {
        shortfall = v;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }
}

contract MockSafe is ISafe {
    bool public shouldFail;

    function setShouldFail(bool v) external {
        shouldFail = v;
    }

    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation)
        external
        returns (bool)
    {
        if (shouldFail) return false;
        (bool ok,) = to.call{value: value}(data);
        return ok;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, Operation)
        external
        returns (bool, bytes memory)
    {
        if (shouldFail) return (false, "");
        return to.call{value: value}(data);
    }

    receive() external payable {}
}

contract PawthereumMamoYieldModuleTest is Test {
    MockERC20 internal usdc;
    MockMToken internal mToken;
    MockMorphoVault internal morpho;
    MockMamoStrategy internal strategy;
    MockSafe internal safe;
    PawthereumMamoYieldModule internal module;

    address internal donation = address(0xD0);
    address internal dev = address(0xDE);
    address internal poker = address(0xBEEF);

    uint256 internal constant PRINCIPAL = 1_000_000e6; // 1M USDC
    uint256 internal constant INTERVAL = 7 days;
    uint256 internal constant MIN_CLAIM = 1e6; // 1 USDC

    function setUp() public {
        usdc = new MockERC20();
        mToken = new MockMToken();
        morpho = new MockMorphoVault();
        strategy = new MockMamoStrategy(usdc);
        safe = new MockSafe();

        module = new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );

        // start at a non-zero timestamp so first call passes the time check immediately
        vm.warp(INTERVAL + 1);
    }

    // ---------- Constructor ----------

    function test_RevertOnZeroSafe() public {
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        new PawthereumMamoYieldModule(
            address(0),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
    }

    function test_RevertOnZeroStrategy() public {
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        new PawthereumMamoYieldModule(
            address(safe),
            address(0),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
    }

    function test_RevertOnZeroDonationRecipient() public {
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            address(0),
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
    }

    function test_ConstructorSetsAllImmutablesAndState() public view {
        assertEq(module.SAFE(), address(safe));
        assertEq(module.MAMO_STRATEGY(), address(strategy));
        assertEq(module.USDC(), address(usdc));
        assertEq(module.M_TOKEN(), address(mToken));
        assertEq(module.META_MORPHO_VAULT(), address(morpho));
        assertEq(module.donationRecipient(), donation);
        assertEq(module.devRecipient(), dev);
        assertEq(module.protectedPrincipal(), PRINCIPAL);
        assertEq(module.executionInterval(), INTERVAL);
        assertEq(module.minimumClaimAmount(), MIN_CLAIM);
        assertFalse(module.paused());
    }

    // ---------- getStrategyValue ----------

    function test_GetStrategyValueSumsAllThreeSources() public {
        morpho.setShares(address(strategy), 100e6);
        morpho.setRate(1.1e18); // 100 shares -> 110 USDC
        mToken.set(address(strategy), 200e6);
        usdc.mint(address(strategy), 50e6);

        assertEq(module.getStrategyValue(), 110e6 + 200e6 + 50e6);
    }

    function test_GetStrategyValueReturnsZeroWhenEmpty() public {
        assertEq(module.getStrategyValue(), 0);
    }

    function test_GetStrategyValueSkipsConvertWhenNoShares() public {
        // intentionally do not set rate; no shares => no convertToAssets call
        mToken.set(address(strategy), 7);
        assertEq(module.getStrategyValue(), 7);
    }

    // ---------- Happy path ----------

    function _seedStrategyWithYield(uint256 strategyValue) internal {
        // strategy holds all value as idle USDC for simplicity (other components stay 0)
        usdc.mint(address(strategy), strategyValue);
    }

    function test_HappyPath() public {
        uint256 strategyValue = PRINCIPAL + 100e6; // 100 USDC of yield
        _seedStrategyWithYield(strategyValue);

        vm.prank(poker);
        (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount
        ) = module.executeWeeklyYieldCapture();

        assertEq(strategyValueBefore, strategyValue);
        assertEq(totalYield, 100e6);
        assertEq(claimedYield, 90e6); // 90% of 100
        assertEq(donationAmount, 45e6);
        assertEq(devAmount, 45e6);

        assertEq(usdc.balanceOf(donation), 45e6);
        assertEq(usdc.balanceOf(dev), 45e6);
        assertEq(usdc.balanceOf(address(safe)), 0); // Safe forwarded everything
        assertEq(usdc.balanceOf(address(strategy)), strategyValue - claimedYield);

        // auto-ratchet: principal grew by the unclaimed 10%
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6);
        assertEq(module.lastExecutionTimestamp(), block.timestamp);
    }

    function test_AutoRatchetCompoundsAcrossMultipleCycles() public {
        // first cycle: 100 USDC yield -> 10 USDC ratcheted
        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        module.executeWeeklyYieldCapture();
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6);

        // second cycle: simulate 50 USDC of new yield arriving (idle USDC grew further)
        usdc.mint(address(strategy), 50e6);
        vm.warp(block.timestamp + INTERVAL);

        vm.prank(poker);
        (, uint256 totalYield2, uint256 claimedYield2,,) = module.executeWeeklyYieldCapture();

        // strategy now sits at PRINCIPAL + 100 - 90 + 50 = PRINCIPAL + 60. Floor was bumped to PRINCIPAL + 10.
        // so yield this cycle = 50, claim = 45.
        assertEq(totalYield2, 50e6);
        assertEq(claimedYield2, 45e6);
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6 + 5e6);
    }

    function test_HandlesSafeIdleUSDCInExcessOfPrincipal() public {
        // strategy at exactly principal; safe holds extra USDC that should count as yield
        _seedStrategyWithYield(PRINCIPAL);
        usdc.mint(address(safe), 200e6);

        vm.prank(poker);
        (,, uint256 claimedYield,,) = module.executeWeeklyYieldCapture();

        // total yield = (PRINCIPAL + 200) + 0 - PRINCIPAL = 200; claim = 180; dev/donation = 90 each
        assertEq(claimedYield, 180e6);
        // donation got 90, dev got 90; safe started with 200, ended with 200 - 180 + 0 (no withdraw needed since strategy idle is 1M)
        // strategy had to give up 180 from its own idle pool
        assertEq(usdc.balanceOf(donation), 90e6);
        assertEq(usdc.balanceOf(dev), 90e6);
    }

    // ---------- Reverts ----------

    function test_RevertWhenPaused() public {
        vm.prank(address(safe));
        module.pause();

        _seedStrategyWithYield(PRINCIPAL + 100e6);
        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.IsPaused.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenTooEarly() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        module.executeWeeklyYieldCapture();

        // immediately try again -- should revert
        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.TooEarly.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenNoYield() public {
        _seedStrategyWithYield(PRINCIPAL); // exactly principal, zero yield

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.NoYield.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenBelowMinimumClaim() public {
        // tiny yield (1 USDC -> 0.9 USDC claim) but min is 1 USDC
        _seedStrategyWithYield(PRINCIPAL + 1e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.BelowMinimum.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenWithdrawShortDelivers() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);
        strategy.setShortfall(int256(1)); // delivers 1 wei less than requested

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.WithdrawFailed.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenSafeCallFails() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);
        safe.setShouldFail(true);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.SafeCallFailed.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenPrincipalViolationDetected() public {
        // EvilStrategy delivers the requested amount but secretly burns the rest of its USDC
        // before returning, so the final invariant check fails.
        EvilStrategy evil = new EvilStrategy(usdc);
        PawthereumMamoYieldModule m2 = new PawthereumMamoYieldModule(
            address(safe),
            address(evil),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        usdc.mint(address(evil), PRINCIPAL + 100e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.PrincipalViolation.selector);
        m2.executeWeeklyYieldCapture();
    }

    // ---------- Preview ----------

    function test_PreviewMatchesExecutionWhenExecutable() public {
        _seedStrategyWithYield(PRINCIPAL + 200e6);

        (
            uint256 pStrategyValue,
            ,
            uint256 pTotalYield,
            uint256 pClaimedYield,
            uint256 pDonationAmount,
            uint256 pDevAmount,
            bool canExecute
        ) = module.previewYieldCapture();

        assertTrue(canExecute);
        assertEq(pTotalYield, 200e6);
        assertEq(pClaimedYield, 180e6);

        vm.prank(poker);
        (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount
        ) = module.executeWeeklyYieldCapture();

        assertEq(pStrategyValue, strategyValueBefore);
        assertEq(pTotalYield, totalYield);
        assertEq(pClaimedYield, claimedYield);
        assertEq(pDonationAmount, donationAmount);
        assertEq(pDevAmount, devAmount);
    }

    function test_PreviewReportsCannotExecuteWhenPaused() public {
        _seedStrategyWithYield(PRINCIPAL + 200e6);
        vm.prank(address(safe));
        module.pause();

        (,,,,,, bool canExecute) = module.previewYieldCapture();
        assertFalse(canExecute);
    }

    function test_PreviewReportsCannotExecuteBelowMinimum() public {
        _seedStrategyWithYield(PRINCIPAL + 1e6);
        (,,, uint256 claimedYield,,, bool canExecute) = module.previewYieldCapture();
        assertEq(claimedYield, 0.9e6);
        assertFalse(canExecute);
    }

    // ---------- Admin ----------

    function test_AdminSettersRevertWhenNotSafe() public {
        vm.startPrank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setDonationRecipient(address(0x99));
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setDevRecipient(address(0x99));
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setProtectedPrincipal(1);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setExecutionInterval(1);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setMinimumClaimAmount(1);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.pause();
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.unpause();
        vm.stopPrank();
    }

    function test_AdminSettersHappyPath() public {
        vm.startPrank(address(safe));

        module.setDonationRecipient(address(0x111));
        assertEq(module.donationRecipient(), address(0x111));

        module.setDevRecipient(address(0x222));
        assertEq(module.devRecipient(), address(0x222));

        module.setProtectedPrincipal(42);
        assertEq(module.protectedPrincipal(), 42);

        module.setExecutionInterval(1 days);
        assertEq(module.executionInterval(), 1 days);

        module.setMinimumClaimAmount(99);
        assertEq(module.minimumClaimAmount(), 99);

        module.pause();
        assertTrue(module.paused());
        module.unpause();
        assertFalse(module.paused());

        vm.stopPrank();
    }

    function test_SetRecipientRevertsOnZeroAddress() public {
        vm.startPrank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        module.setDonationRecipient(address(0));
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        module.setDevRecipient(address(0));
        vm.stopPrank();
    }

    // ---------- Audit fixes ----------

    function test_SetExecutionIntervalRevertsOnZero() public {
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.InvalidExecutionInterval.selector);
        module.setExecutionInterval(0);
    }

    function test_RevertWhenRatchetWouldViolateInvariant() public {
        // RoundingShortStrategy delivers `amount` but burns 1 wei of its own balance
        // afterwards. Final sum == newPrincipal - 1, which would have silently passed
        // against the OLD principal but must revert against the new one.
        RoundingShortStrategy shortStrat = new RoundingShortStrategy(usdc);
        PawthereumMamoYieldModule m2 = new PawthereumMamoYieldModule(
            address(safe),
            address(shortStrat),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        usdc.mint(address(shortStrat), PRINCIPAL + 100e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.PrincipalViolation.selector);
        m2.executeWeeklyYieldCapture();
    }

    function test_RevertWhenUSDCTransferReturnsFalseSilently() public {
        // Wire the module to a token that lies ONLY when the Safe calls transfer (donation/dev
        // path). Strategy-to-Safe transfer during withdraw must still succeed so we actually
        // reach the donation/dev step -- that's the path we want to exercise.
        LyingUSDC lying = new LyingUSDC(address(safe));
        LyingTokenStrategy lyingStrat = new LyingTokenStrategy(lying);

        PawthereumMamoYieldModule m2 = new PawthereumMamoYieldModule(
            address(safe),
            address(lyingStrat),
            address(lying),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        lying.mint(address(lyingStrat), PRINCIPAL + 100e6);

        // expectCall asserts the donation `transfer` was *attempted* during execution (call
        // traces survive parent reverts). This is what proves the test exercises the
        // false-bool path rather than an earlier revert during withdraw.
        vm.expectCall(address(lying), abi.encodeCall(LyingUSDC.transfer, (donation, 45e6)));

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.SafeCallFailed.selector);
        m2.executeWeeklyYieldCapture();
    }

    function test_RevertOnZeroExecutionIntervalConstructor() public {
        vm.expectRevert(PawthereumMamoYieldModule.InvalidExecutionInterval.selector);
        new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            donation,
            dev,
            PRINCIPAL,
            0,
            MIN_CLAIM
        );
    }
}

// Strategy that delivers the requested amount but burns the remainder of its USDC
// before returning -- forces the final invariant check to fail.
contract EvilStrategy {
    MockERC20 public immutable usdc;
    address internal constant BURN = address(0xDEAD);

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function withdraw(uint256 amount) external {
        usdc.transfer(msg.sender, amount);
        uint256 remaining = usdc.balanceOf(address(this));
        if (remaining > 0) usdc.transfer(BURN, remaining);
    }
}

// Strategy that delivers the requested amount but burns exactly 1 wei of leftover USDC,
// causing the post-execution sum to fall 1 wei short of the new (ratcheted) principal.
// Without the audit Fix 1 ordering, this would silently pass.
contract RoundingShortStrategy {
    MockERC20 public immutable usdc;
    address internal constant BURN = address(0xDEAD);

    constructor(MockERC20 _usdc) {
        usdc = _usdc;
    }

    function withdraw(uint256 amount) external {
        usdc.transfer(msg.sender, amount);
        // burn 1 wei of leftover USDC -- enough to make sum_after == newPrincipal - 1
        usdc.transfer(BURN, 1);
    }
}

// USDC variant whose `transfer` returns false without moving balances -- but ONLY when
// invoked by `lieToSender` (the Safe). Other callers get an honest transfer so the strategy
// can actually deliver the claim into the Safe. This shape lets us exercise the false-bool
// path on the donation/dev transfers without the test reverting earlier inside withdraw.
contract LyingUSDC {
    mapping(address => uint256) public balanceOf;
    address public immutable lieToSender;

    constructor(address _lieToSender) {
        lieToSender = _lieToSender;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (msg.sender == lieToSender) return false;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

// Strategy that uses LyingUSDC for its withdraw -- so getStrategyValue and withdraw both
// go through the lying token. Withdraw transfers from the strategy (msg.sender to LyingUSDC
// is the strategy, not lieToSender), so it succeeds and delivers tokens to the Safe.
contract LyingTokenStrategy {
    LyingUSDC public immutable token;

    constructor(LyingUSDC _token) {
        token = _token;
    }

    function withdraw(uint256 amount) external {
        token.transfer(msg.sender, amount);
    }
}
