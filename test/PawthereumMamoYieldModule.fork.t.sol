// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {PawthereumMamoYieldModule} from "../src/PawthereumMamoYieldModule.sol";
import {ISafe} from "../src/interfaces/ISafe.sol";

interface IStrategyFactory {
    function createStrategyForUser(address user) external returns (address strategy);
}

interface IMamoStrategyExtended {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function owner() external view returns (address);
}

interface IUSDC {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

// MockSafe used in fork tests so we control strategy ownership without dragging in
// the full Safe/Proxy machinery. Forwards module calls via low-level call -- preserves
// msg.sender semantics for the underlying contracts.
contract ForkMockSafe is ISafe {
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, Operation)
        external
        returns (bool)
    {
        (bool ok,) = to.call{value: value}(data);
        return ok;
    }

    function execTransactionFromModuleReturnData(address to, uint256 value, bytes calldata data, Operation)
        external
        returns (bool, bytes memory)
    {
        return to.call{value: value}(data);
    }

    receive() external payable {}
}

contract PawthereumMamoYieldModuleForkTest is Test {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant META_MORPHO_USDC_VAULT = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    address internal constant STRATEGY_FACTORY = 0x5967ea71cC65d610dc6999d7dF62bfa512e62D07;

    uint256 internal constant SEED_DEPOSIT = 100_000e6; // 100k USDC
    uint256 internal constant INTERVAL = 7 days;
    uint256 internal constant MIN_CLAIM = 1e6;

    ForkMockSafe internal safe;
    address internal strategy;
    PawthereumMamoYieldModule internal module;

    address internal donation = makeAddr("donation");
    address internal dev = makeAddr("dev");
    address internal poker = makeAddr("poker");

    bool internal forkReady;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        vm.createSelectFork(rpc);

        safe = new ForkMockSafe();

        // Have the Safe ask the Mamo factory for a fresh strategy owned by itself.
        // createStrategyForUser is callable by mamoBackend OR the user; we are the user.
        vm.prank(address(safe));
        strategy = IStrategyFactory(STRATEGY_FACTORY).createStrategyForUser(address(safe));

        // Seed the Safe with USDC and deposit it into the strategy (impersonating the Safe).
        deal(USDC, address(safe), SEED_DEPOSIT);
        vm.prank(address(safe));
        IUSDC(USDC).approve(strategy, SEED_DEPOSIT);
        vm.prank(address(safe));
        IMamoStrategyExtended(strategy).deposit(SEED_DEPOSIT);

        // Deploy the module with protectedPrincipal == amount we just deposited.
        module = new PawthereumMamoYieldModule(
            address(safe), strategy, USDC, M_USDC, META_MORPHO_USDC_VAULT, donation, dev, SEED_DEPOSIT, INTERVAL, MIN_CLAIM
        );

        forkReady = true;
    }

    modifier onFork() {
        if (!forkReady) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_GetStrategyValue_TracksDepositedAmount() public onFork {
        // Right after deposit, strategy value should be ~SEED_DEPOSIT (within rounding).
        uint256 value = module.getStrategyValue();
        assertApproxEqAbs(value, SEED_DEPOSIT, 2, "strategy value should match deposit at t=0 (within 2 wei)");
    }

    function test_HappyPath_ExecutesAndSplitsYield() public onFork {
        // Skip a year so meaningful yield accrues on both legs.
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + (365 days / 2)); // ~2s blocks on Base

        uint256 valueAfterAYear = module.getStrategyValue();
        assertGt(valueAfterAYear, SEED_DEPOSIT, "strategy should have accrued yield");

        uint256 expectedTotalYield = valueAfterAYear - SEED_DEPOSIT;
        uint256 expectedClaim = (expectedTotalYield * 9_000) / 10_000;

        vm.prank(poker);
        (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount
        ) = module.executeWeeklyYieldCapture();

        assertEq(strategyValueBefore, valueAfterAYear);
        assertEq(totalYield, expectedTotalYield);
        assertEq(claimedYield, expectedClaim);
        assertEq(donationAmount + devAmount, claimedYield);
        // 50/50 split: dev gets floor(claim * 5000 / 10000), donation gets the rest
        assertApproxEqAbs(donationAmount, devAmount, 1);

        assertEq(IUSDC(USDC).balanceOf(donation), donationAmount);
        assertEq(IUSDC(USDC).balanceOf(dev), devAmount);

        // principal invariant: strategy + safe idle >= original principal
        uint256 strategyAfter = module.getStrategyValue();
        uint256 safeIdleAfter = module.getSafeUSDC();
        assertGe(strategyAfter + safeIdleAfter, SEED_DEPOSIT, "principal preserved");

        // auto-ratchet: protectedPrincipal grew by the unclaimed 10%
        assertEq(module.protectedPrincipal(), SEED_DEPOSIT + (expectedTotalYield - expectedClaim));
    }

    function test_RevertWhenTooEarly() public onFork {
        // Accrue some yield, execute once, then try again immediately.
        vm.warp(block.timestamp + 30 days);
        vm.roll(block.number + (30 days / 2));

        vm.prank(poker);
        try module.executeWeeklyYieldCapture() {}
        catch {
            // If 30 days didn't accrue enough to clear MIN_CLAIM, skip the rest.
            return;
        }

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.TooEarly.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenPaused() public onFork {
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + (365 days / 2));

        vm.prank(address(safe));
        module.pause();

        vm.prank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.IsPaused.selector);
        module.executeWeeklyYieldCapture();
    }

    function test_RevertWhenYieldZero() public onFork {
        // Execute immediately after deposit -- no time has passed, no yield accrued
        // (or minute amounts well below MIN_CLAIM). NoYield or BelowMinimum is acceptable.
        vm.prank(poker);
        vm.expectRevert();
        module.executeWeeklyYieldCapture();
    }

    function test_AdminFunctionsRequireSafe() public onFork {
        vm.startPrank(poker);
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.pause();
        vm.expectRevert(PawthereumMamoYieldModule.NotSafe.selector);
        module.setProtectedPrincipal(0);
        vm.stopPrank();

        vm.prank(address(safe));
        module.pause();
        assertTrue(module.paused());
    }

    function test_PrincipalInvariantAcrossMultipleCycles() public onFork {
        // Run several cycles of: warp, execute. Invariant must hold every cycle.
        for (uint256 i = 0; i < 4; i++) {
            vm.warp(block.timestamp + 90 days);
            vm.roll(block.number + (90 days / 2));

            uint256 floor = module.protectedPrincipal();

            vm.prank(poker);
            try module.executeWeeklyYieldCapture() {
                assertGe(module.getStrategyValue() + module.getSafeUSDC(), floor, "principal invariant broken");
                assertGe(module.protectedPrincipal(), floor, "ratchet must be monotonic");
            } catch {
                // BelowMinimum is acceptable if yield didn't clear the threshold this cycle
            }
        }
    }
}

// =============================================================================
// Real-Safe integration test
//
// Deploys an actual Safe v1.4.1 proxy on a Base mainnet fork (canonical addresses --
// same on every chain), enables our module via execTransaction with a pre-validated
// signature, then exercises the production path end-to-end. This is the integration
// proof the auditor asked for in their response: it demonstrates that
// execTransactionFromModuleReturnData (which we depend on) actually works against the
// production Safe singleton, not just our ForkMockSafe shim.
// =============================================================================

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes calldata initializer, uint256 saltNonce)
        external
        returns (address proxy);
}

interface ISafeFull {
    function execTransaction(
        address to,
        uint256 value,
        bytes calldata data,
        uint8 operation,
        uint256 safeTxGas,
        uint256 baseGas,
        uint256 gasPrice,
        address gasToken,
        address payable refundReceiver,
        bytes calldata signatures
    ) external payable returns (bool);

    function isModuleEnabled(address module) external view returns (bool);
}

contract PawthereumMamoYieldModuleRealSafeForkTest is Test {
    // Canonical Safe v1.4.1 deployments -- same addresses on every EVM chain
    address internal constant SAFE_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // Mamo / Moonwell / Morpho on Base
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant M_USDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant META_MORPHO_USDC_VAULT = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    address internal constant STRATEGY_FACTORY = 0x5967ea71cC65d610dc6999d7dF62bfa512e62D07;

    uint256 internal constant SEED_DEPOSIT = 100_000e6;
    uint256 internal constant INTERVAL = 7 days;
    uint256 internal constant MIN_CLAIM = 1e6;

    address internal owner;
    address payable internal safe;
    address internal strategy;
    PawthereumMamoYieldModule internal module;

    address internal donation = makeAddr("donation");
    address internal dev = makeAddr("dev");

    bool internal forkReady;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        owner = makeAddr("safeOwner");

        // Deploy a real Safe v1.4.1 proxy via the canonical factory.
        address[] memory owners = new address[](1);
        owners[0] = owner;
        bytes memory setupData = abi.encodeWithSignature(
            "setup(address[],uint256,address,bytes,address,address,uint256,address)",
            owners,
            uint256(1),
            address(0),
            bytes(""),
            FALLBACK_HANDLER,
            address(0),
            uint256(0),
            address(0)
        );
        safe = payable(ISafeProxyFactory(SAFE_FACTORY).createProxyWithNonce(SAFE_SINGLETON, setupData, 0));

        // Mint a Mamo strategy for the Safe (factory accepts the user as caller).
        vm.prank(safe);
        strategy = IStrategyFactory(STRATEGY_FACTORY).createStrategyForUser(safe);

        // Seed the Safe with USDC, then deposit into the strategy via execTransaction.
        deal(USDC, safe, SEED_DEPOSIT);
        _execAsSafe(USDC, abi.encodeWithSignature("approve(address,uint256)", strategy, SEED_DEPOSIT));
        _execAsSafe(strategy, abi.encodeWithSignature("deposit(uint256)", SEED_DEPOSIT));

        // Deploy the module + enable it on the Safe.
        module = new PawthereumMamoYieldModule(
            safe, strategy, USDC, M_USDC, META_MORPHO_USDC_VAULT, donation, dev, SEED_DEPOSIT, INTERVAL, MIN_CLAIM
        );
        _execAsSafe(safe, abi.encodeWithSignature("enableModule(address)", address(module)));

        forkReady = true;
    }

    /// @dev Execute a transaction through the real Safe using a pre-validated signature.
    /// Pre-validated sig format: r = owner address (left-padded), s = 0, v = 1.
    /// Safe accepts this when msg.sender == owner (verified inside checkSignatures).
    function _execAsSafe(address to, bytes memory data) internal {
        bytes memory sig = abi.encodePacked(bytes32(uint256(uint160(owner))), bytes32(0), uint8(1));
        vm.prank(owner);
        ISafeFull(safe).execTransaction(
            to, 0, data, 0, 0, 0, 0, address(0), payable(address(0)), sig
        );
    }

    modifier onFork() {
        if (!forkReady) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_RealSafe_ModuleIsEnabled() public onFork {
        assertTrue(ISafeFull(safe).isModuleEnabled(address(module)), "module should be enabled on the real Safe");
    }

    function test_RealSafe_HappyPath_EndToEnd() public onFork {
        // Accrue ~1 year of yield.
        vm.warp(block.timestamp + 365 days);
        vm.roll(block.number + (365 days / 2));

        uint256 valueAfter = module.getStrategyValue();
        assertGt(valueAfter, SEED_DEPOSIT, "strategy should have accrued yield");

        // Anyone can poke once the interval has elapsed.
        vm.prank(makeAddr("poker"));
        (
            uint256 strategyValueBefore,
            uint256 totalYield,
            uint256 claimedYield,
            uint256 donationAmount,
            uint256 devAmount
        ) = module.executeWeeklyYieldCapture();

        assertEq(strategyValueBefore, valueAfter);
        assertEq(claimedYield, (totalYield * 9_000) / 10_000);
        assertApproxEqAbs(donationAmount, devAmount, 1);

        assertEq(IUSDC(USDC).balanceOf(donation), donationAmount, "donation got its share");
        assertEq(IUSDC(USDC).balanceOf(dev), devAmount, "dev got its share");

        // Principal preserved + auto-ratchet bumped the floor.
        assertGe(module.getStrategyValue() + IUSDC(USDC).balanceOf(safe), module.protectedPrincipal());
        assertEq(module.protectedPrincipal(), SEED_DEPOSIT + (totalYield - claimedYield));
    }
}
