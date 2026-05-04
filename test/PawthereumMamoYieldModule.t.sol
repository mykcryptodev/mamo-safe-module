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

    address internal alice = address(0xA1);
    address internal bob = address(0xB0B);
    address internal poker = address(0xBEEF);

    uint256 internal constant PRINCIPAL = 1_000_000e6; // 1M USDC
    uint256 internal constant INTERVAL = 7 days;
    uint256 internal constant MIN_CLAIM = 1e6; // 1 USDC

    // Default config: alice 45%, bob 45%, 10% compounds — matches the prior hardcoded behavior
    function _defaultRecipients() internal view returns (PawthereumMamoYieldModule.Recipient[] memory) {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](2);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 4500});
        r[1] = PawthereumMamoYieldModule.Recipient({addr: bob, bps: 4500});
        return r;
    }

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
            _defaultRecipients(),
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
            _defaultRecipients(),
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
            _defaultRecipients(),
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
    }

    function test_RevertOnZeroRecipientAddress() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](1);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: address(0), bps: 5000});

        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            r,
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
        assertEq(module.protectedPrincipal(), PRINCIPAL);
        assertEq(module.executionInterval(), INTERVAL);
        assertEq(module.minimumClaimAmount(), MIN_CLAIM);
        assertFalse(module.paused());
        assertEq(module.recipientCount(), 2);

        PawthereumMamoYieldModule.Recipient[] memory got = module.getRecipients();
        assertEq(got.length, 2);
        assertEq(got[0].addr, alice);
        assertEq(got[0].bps, 4500);
        assertEq(got[1].addr, bob);
        assertEq(got[1].bps, 4500);
    }

    function test_ConstructorAllowsEmptyRecipients() public {
        PawthereumMamoYieldModule.Recipient[] memory empty = new PawthereumMamoYieldModule.Recipient[](0);
        PawthereumMamoYieldModule m = new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            empty,
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        assertEq(m.recipientCount(), 0);
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
            uint256 totalDistributed,
            uint256 compoundedAmount
        ) = module.executeYieldCapture();

        assertEq(strategyValueBefore, strategyValue);
        assertEq(totalYield, 100e6);
        // alice 45% + bob 45% = 90 USDC distributed; 10% compounds
        assertEq(totalDistributed, 90e6);
        assertEq(compoundedAmount, 10e6);

        assertEq(usdc.balanceOf(alice), 45e6);
        assertEq(usdc.balanceOf(bob), 45e6);
        assertEq(usdc.balanceOf(address(safe)), 0); // Safe forwarded everything
        assertEq(usdc.balanceOf(address(strategy)), strategyValue - totalDistributed);

        // auto-ratchet: principal grew by the un-distributed remainder
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6);
        assertEq(module.lastExecutionTimestamp(), block.timestamp);
    }

    function test_HappyPath_ThreeRecipients() public {
        // 30/30/30 split, 10% compound
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](3);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 3000});
        r[1] = PawthereumMamoYieldModule.Recipient({addr: bob, bps: 3000});
        address carol = address(0xCA40);
        r[2] = PawthereumMamoYieldModule.Recipient({addr: carol, bps: 3000});

        vm.prank(address(safe));
        module.setRecipients(r);

        _seedStrategyWithYield(PRINCIPAL + 1000e6); // 1000 USDC yield

        vm.prank(poker);
        (, uint256 totalYield, uint256 totalDistributed, uint256 compoundedAmount) =
            module.executeYieldCapture();

        assertEq(totalYield, 1000e6);
        assertEq(totalDistributed, 900e6); // 30+30+30 = 90%
        assertEq(compoundedAmount, 100e6);
        assertEq(usdc.balanceOf(alice), 300e6);
        assertEq(usdc.balanceOf(bob), 300e6);
        assertEq(usdc.balanceOf(carol), 300e6);
        assertEq(module.protectedPrincipal(), PRINCIPAL + 100e6);
    }

    function test_HappyPath_FullDistributionNoCompound() public {
        // 50/50, sum == 10000, nothing compounds
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](2);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 5000});
        r[1] = PawthereumMamoYieldModule.Recipient({addr: bob, bps: 5000});

        vm.prank(address(safe));
        module.setRecipients(r);

        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        (, uint256 totalYield, uint256 totalDistributed, uint256 compoundedAmount) =
            module.executeYieldCapture();

        assertEq(totalYield, 100e6);
        assertEq(totalDistributed, 100e6);
        assertEq(compoundedAmount, 0);
        assertEq(module.protectedPrincipal(), PRINCIPAL);
    }

    function test_HappyPath_EmptyRecipientsCompoundsEverything() public {
        // No recipients = 100% compound. Min claim must be 0 since totalDistributed = 0.
        vm.prank(address(safe));
        module.setMinimumClaimAmount(0);

        PawthereumMamoYieldModule.Recipient[] memory empty = new PawthereumMamoYieldModule.Recipient[](0);
        vm.prank(address(safe));
        module.setRecipients(empty);

        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        (, uint256 totalYield, uint256 totalDistributed, uint256 compoundedAmount) =
            module.executeYieldCapture();

        assertEq(totalYield, 100e6);
        assertEq(totalDistributed, 0);
        assertEq(compoundedAmount, 100e6);
        assertEq(usdc.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(bob), 0);
        // strategy untouched
        assertEq(usdc.balanceOf(address(strategy)), PRINCIPAL + 100e6);
        assertEq(module.protectedPrincipal(), PRINCIPAL + 100e6);
    }

    function test_AutoRatchetCompoundsAcrossMultipleCycles() public {
        // first cycle: 100 USDC yield -> 10 USDC ratcheted
        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        module.executeYieldCapture();
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6);

        // second cycle: simulate 50 USDC of new yield arriving (idle USDC grew further)
        usdc.mint(address(strategy), 50e6);
        vm.warp(block.timestamp + INTERVAL);

        vm.prank(poker);
        (, uint256 totalYield2, uint256 totalDistributed2,) = module.executeYieldCapture();

        // strategy now sits at PRINCIPAL + 100 - 90 + 50 = PRINCIPAL + 60. Floor was bumped to PRINCIPAL + 10.
        // so yield this cycle = 50, distributed = 45.
        assertEq(totalYield2, 50e6);
        assertEq(totalDistributed2, 45e6);
        assertEq(module.protectedPrincipal(), PRINCIPAL + 10e6 + 5e6);
    }

    function test_HandlesSafeIdleUSDCInExcessOfPrincipal() public {
        // strategy at exactly principal; safe holds extra USDC that should count as yield
        _seedStrategyWithYield(PRINCIPAL);
        usdc.mint(address(safe), 200e6);

        vm.prank(poker);
        (,, uint256 totalDistributed,) = module.executeYieldCapture();

        // total yield = (PRINCIPAL + 200) + 0 - PRINCIPAL = 200; distributed = 180
        assertEq(totalDistributed, 180e6);
        assertEq(usdc.balanceOf(alice), 90e6);
        assertEq(usdc.balanceOf(bob), 90e6);
    }

    // ---------- Reverts ----------

    function test_RevertWhenPaused() public {
        vm.prank(address(safe));
        module.pause();

        _seedStrategyWithYield(PRINCIPAL + 100e6);
        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.IsPaused.selector);
        module.executeYieldCapture();
    }

    function test_RevertWhenTooEarly() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.prank(poker);
        module.executeYieldCapture();

        // immediately try again -- should revert
        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.TooEarly.selector);
        module.executeYieldCapture();
    }

    function test_RevertWhenNoYield() public {
        _seedStrategyWithYield(PRINCIPAL); // exactly principal, zero yield

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.NoYield.selector);
        module.executeYieldCapture();
    }

    function test_RevertWhenAllRecipientAmountsRoundToZero() public {
        // Griefing scenario: recipients configured + minimumClaimAmount = 0 + dust yield
        // small enough that every (totalYield * bps) / 10000 floors to 0.
        // Without the guard, anyone could consume the interval without paying recipients.
        vm.prank(address(safe));
        module.setMinimumClaimAmount(0);

        // totalYield = 1 wei. (1 * 4500) / 10000 = 0 for both recipients.
        _seedStrategyWithYield(PRINCIPAL + 1);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.BelowMinimum.selector);
        module.executeYieldCapture();
    }

    function test_PreviewReportsCannotExecuteWhenAllAmountsRoundToZero() public {
        vm.prank(address(safe));
        module.setMinimumClaimAmount(0);
        _seedStrategyWithYield(PRINCIPAL + 1);

        PawthereumMamoYieldModule.Preview memory p = module.previewYieldCapture();
        assertEq(p.totalYield, 1);
        assertEq(p.totalDistributed, 0);
        assertFalse(p.canExecute);
    }

    function test_RevertWhenBelowMinimumClaim() public {
        // tiny yield (1 USDC -> 0.9 USDC distributed) but min is 1 USDC
        _seedStrategyWithYield(PRINCIPAL + 1e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.BelowMinimum.selector);
        module.executeYieldCapture();
    }

    function test_RevertWhenWithdrawShortDelivers() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);
        strategy.setShortfall(int256(1)); // delivers 1 wei less than requested

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.WithdrawFailed.selector);
        module.executeYieldCapture();
    }

    function test_RevertWhenSafeCallFails() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);
        safe.setShouldFail(true);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.SafeCallFailed.selector);
        module.executeYieldCapture();
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
            _defaultRecipients(),
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        usdc.mint(address(evil), PRINCIPAL + 100e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.PrincipalViolation.selector);
        m2.executeYieldCapture();
    }

    // ---------- Preview ----------

    function test_PreviewMatchesExecutionWhenExecutable() public {
        _seedStrategyWithYield(PRINCIPAL + 200e6);

        PawthereumMamoYieldModule.Preview memory p = module.previewYieldCapture();

        assertTrue(p.canExecute);
        assertEq(p.totalYield, 200e6);
        assertEq(p.totalDistributed, 180e6);
        assertEq(p.compoundedAmount, 20e6);
        assertEq(p.amounts.length, 2);
        assertEq(p.amounts[0], 90e6);
        assertEq(p.amounts[1], 90e6);

        vm.prank(poker);
        (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 totalDistributed,
            uint256 compoundedAmount
        ) = module.executeYieldCapture();

        assertEq(p.strategyValue, strategyValueBefore);
        assertEq(p.totalYield, totalYield);
        assertEq(p.totalDistributed, totalDistributed);
        assertEq(p.compoundedAmount, compoundedAmount);
    }

    function test_PreviewReportsCannotExecuteWhenPaused() public {
        _seedStrategyWithYield(PRINCIPAL + 200e6);
        vm.prank(address(safe));
        module.pause();

        PawthereumMamoYieldModule.Preview memory p = module.previewYieldCapture();
        assertFalse(p.canExecute);
    }

    function test_PreviewReportsCannotExecuteBelowMinimum() public {
        _seedStrategyWithYield(PRINCIPAL + 1e6);
        PawthereumMamoYieldModule.Preview memory p = module.previewYieldCapture();
        assertEq(p.totalDistributed, 0.9e6);
        assertFalse(p.canExecute);
    }

    // ---------- Distribution getter ----------

    function test_GetDistributionReturnsRecipientsAndCompoundBps() public view {
        (PawthereumMamoYieldModule.Recipient[] memory recipients, uint16 compoundBps) =
            module.getDistribution();
        assertEq(recipients.length, 2);
        assertEq(recipients[0].addr, alice);
        assertEq(recipients[0].bps, 4500);
        assertEq(recipients[1].addr, bob);
        assertEq(recipients[1].bps, 4500);
        assertEq(compoundBps, 1000); // 10000 - 4500 - 4500
    }

    function test_GetDistributionEmptyListIsAllCompound() public {
        PawthereumMamoYieldModule.Recipient[] memory empty = new PawthereumMamoYieldModule.Recipient[](0);
        vm.prank(address(safe));
        module.setRecipients(empty);

        (PawthereumMamoYieldModule.Recipient[] memory recipients, uint16 compoundBps) =
            module.getDistribution();
        assertEq(recipients.length, 0);
        assertEq(compoundBps, 10000);
    }

    function test_GetRecipientByIndex() public view {
        (address addr, uint16 bps) = module.getRecipient(0);
        assertEq(addr, alice);
        assertEq(bps, 4500);
        (addr, bps) = module.getRecipient(1);
        assertEq(addr, bob);
        assertEq(bps, 4500);
    }

    // ---------- setRecipients validation ----------

    function test_SetRecipientsRevertsWhenNotSafe() public {
        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setRecipients(_defaultRecipients());
    }

    function test_SetRecipientsRevertsOnZeroAddress() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](1);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: address(0), bps: 5000});
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.ZeroAddress.selector);
        module.setRecipients(r);
    }

    function test_SetRecipientsRevertsOnZeroBps() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](1);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 0});
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.ZeroBps.selector);
        module.setRecipients(r);
    }

    function test_SetRecipientsRevertsOnBpsOverflow() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](2);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 6000});
        r[1] = PawthereumMamoYieldModule.Recipient({addr: bob, bps: 5000});
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.BpsOverflow.selector);
        module.setRecipients(r);
    }

    function test_SetRecipientsRevertsOnDuplicate() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](2);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 1000});
        r[1] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 1000});
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.DuplicateRecipient.selector);
        module.setRecipients(r);
    }

    function test_SetRecipientsRevertsWhenTooMany() public {
        uint256 maxPlusOne = module.MAX_RECIPIENTS() + 1;
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](maxPlusOne);
        for (uint256 i; i < maxPlusOne; ++i) {
            r[i] = PawthereumMamoYieldModule.Recipient({addr: address(uint160(0x1000 + i)), bps: 1});
        }
        vm.prank(address(safe));
        vm.expectRevert(PawthereumMamoYieldModule.TooManyRecipients.selector);
        module.setRecipients(r);
    }

    function test_SetRecipientsAcceptsAtMax() public {
        uint256 max = module.MAX_RECIPIENTS();
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](max);
        for (uint256 i; i < max; ++i) {
            r[i] = PawthereumMamoYieldModule.Recipient({addr: address(uint160(0x1000 + i)), bps: 1});
        }
        vm.prank(address(safe));
        module.setRecipients(r);
        assertEq(module.recipientCount(), max);
    }

    function test_SetRecipientsReplacesExistingList() public {
        // replace the default 2-recipient list with a single recipient
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](1);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 7000});
        vm.prank(address(safe));
        module.setRecipients(r);

        assertEq(module.recipientCount(), 1);
        (address addr, uint16 bps) = module.getRecipient(0);
        assertEq(addr, alice);
        assertEq(bps, 7000);
    }

    function test_SetRecipientsEmitsEvent() public {
        PawthereumMamoYieldModule.Recipient[] memory r = new PawthereumMamoYieldModule.Recipient[](1);
        r[0] = PawthereumMamoYieldModule.Recipient({addr: alice, bps: 7000});

        vm.expectEmit(false, false, false, true, address(module));
        emit PawthereumMamoYieldModule.RecipientsUpdated(r, 3000);

        vm.prank(address(safe));
        module.setRecipients(r);
    }

    function test_ExecuteEmitsYieldDistributedPerRecipient() public {
        _seedStrategyWithYield(PRINCIPAL + 100e6);

        vm.expectEmit(true, false, false, true, address(module));
        emit PawthereumMamoYieldModule.YieldDistributed(alice, 45e6);
        vm.expectEmit(true, false, false, true, address(module));
        emit PawthereumMamoYieldModule.YieldDistributed(bob, 45e6);

        vm.prank(poker);
        module.executeYieldCapture();
    }

    // ---------- Other admin ----------

    function test_AdminSettersRevertWhenNotSafe() public {
        vm.startPrank(poker);
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
            _defaultRecipients(),
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        usdc.mint(address(shortStrat), PRINCIPAL + 100e6);

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.PrincipalViolation.selector);
        m2.executeYieldCapture();
    }

    function test_RevertWhenUSDCTransferReturnsFalseSilently() public {
        // Wire the module to a token that lies ONLY when the Safe calls transfer (recipient
        // payout path). Strategy-to-Safe transfer during withdraw must still succeed so we
        // actually reach the recipient payout step -- that's the path we want to exercise.
        LyingUSDC lying = new LyingUSDC(address(safe));
        LyingTokenStrategy lyingStrat = new LyingTokenStrategy(lying);

        PawthereumMamoYieldModule m2 = new PawthereumMamoYieldModule(
            address(safe),
            address(lyingStrat),
            address(lying),
            address(mToken),
            address(morpho),
            _defaultRecipients(),
            PRINCIPAL,
            INTERVAL,
            MIN_CLAIM
        );
        lying.mint(address(lyingStrat), PRINCIPAL + 100e6);

        // expectCall asserts the alice `transfer` was *attempted* during execution (call
        // traces survive parent reverts). This is what proves the test exercises the
        // false-bool path rather than an earlier revert during withdraw.
        vm.expectCall(address(lying), abi.encodeCall(LyingUSDC.transfer, (alice, 45e6)));

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.SafeCallFailed.selector);
        m2.executeYieldCapture();
    }

    function test_RevertOnZeroExecutionIntervalConstructor() public {
        vm.expectRevert(PawthereumMamoYieldModule.InvalidExecutionInterval.selector);
        new PawthereumMamoYieldModule(
            address(safe),
            address(strategy),
            address(usdc),
            address(mToken),
            address(morpho),
            _defaultRecipients(),
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
// path on the recipient transfers without the test reverting earlier inside withdraw.
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
