// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {IAeroGauge} from "../../../contracts/BIFI/interfaces/aero/IAeroGauge.sol";
import {IAeroPair} from "../../../contracts/BIFI/interfaces/aero/IAeroPair.sol";
import {IAeroRouter} from "../../../contracts/BIFI/interfaces/aero/IAeroRouter.sol";
import {IFeeConfig} from "../../../contracts/BIFI/interfaces/common/IFeeConfig.sol";
import {IERC20} from "@openzeppelin-4/contracts/token/ERC20/IERC20.sol";
import {StrategyAero} from "../../../contracts/BIFI/strategies/Aero/StrategyAero.sol";
import {StratFeeManagerInitializable} from "../../../contracts/BIFI/strategies/Common/StratFeeManagerInitializable.sol";

contract MockFeeConfig is IFeeConfig {
    FeeCategory private fees;

    function setFees(uint256 total, uint256 beefy, uint256 call, uint256 strategist) external {
        fees = FeeCategory({
            total: total,
            beefy: beefy,
            call: call,
            strategist: strategist,
            label: "test",
            active: true
        });
    }

    function getFees(address) external view returns (FeeCategory memory) {
        return fees;
    }

    function stratFeeId(address) external pure returns (uint256) {
        return 0;
    }

    function setStratFeeId(uint256) external {}
}

contract MockSwapper {
    function swap(address fromToken, address toToken, uint256 amountIn) external returns (uint256 amountOut) {
        return _swap(fromToken, toToken, amountIn);
    }

    function swap(address fromToken, address toToken, uint256 amountIn, uint256) external returns (uint256 amountOut) {
        return _swap(fromToken, toToken, amountIn);
    }

    function getAmountOut(address, address, uint256 amountIn) external pure returns (uint256 amountOut) {
        return amountIn;
    }

    function _swap(address fromToken, address toToken, uint256 amountIn) private returns (uint256 amountOut) {
        IERC20(fromToken).transferFrom(msg.sender, address(this), amountIn);
        IERC20(toToken).transfer(msg.sender, amountIn);
        return amountIn;
    }
}

contract StrategyAeroHarness is StrategyAero {
    function recordClaimedRewards(uint256 balanceBefore) external {
        _recordClaimedRewards(balanceBefore);
    }
}

/// @notice Incremental fork coverage for the Aero V2 strategy migration.
/// @dev Add each new Aero behaviour here as it becomes available on Base.
contract StrategyAeroTest is Test {
    address private constant AERO = 0x3f5bF3EdAc59d650D8fDf9657a71F2f904A3a4Ee;
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant AERO_USDC_PAIR = 0xF634058dC94e6BF8e828E27621320C423bC8B18E;
    address private constant AERO_USDC_GAUGE = 0xd424BA8ca9d4E278753DE76651a0095451e65cD1;
    address private constant AERO_UNIVERSAL_ROUTER = 0x0fEf9e88A7b76BCDBF451780C6774FE32965Ee98;
    address private constant STRATEGIST = address(0x1001);
    address private constant BEEFY_FEE_RECIPIENT = address(0x1002);
    bytes32 private constant V2_VOLATILE_POOL_TYPE = 0x56325f564f4c4154494c45000000000000000000000000000000000000000000;

    MockFeeConfig private feeConfig;
    MockSwapper private swapper;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_RPC"));
        feeConfig = new MockFeeConfig();
        swapper = new MockSwapper();
    }

    function testAeroUsdcPairIsSupportedV2VolatilePool() public view {
        IAeroPair pair = IAeroPair(AERO_USDC_PAIR);

        assertEq(pair.POOL_TYPE(), V2_VOLATILE_POOL_TYPE);
        assertEq(pair.token0(), AERO);
        assertEq(pair.token1(), USDC);
    }

    function testAeroUsdcGaugeStakesPair() public view {
        IAeroGauge gauge = IAeroGauge(AERO_USDC_GAUGE);

        assertTrue(gauge.isPool());
        assertEq(gauge.stakingToken(), AERO_USDC_PAIR);
    }

    function testAeroUniversalRouterIsDeployed() public view {
        assertGt(AERO_UNIVERSAL_ROUTER.code.length, 0);
    }

    function testGaugeIsDisabledByDefaultAndOwnerCanToggleIt() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        assertEq(strategy.unirouter(), address(swapper));
        assertEq(strategy.aeroRouter(), AERO_UNIVERSAL_ROUTER);
        assertEq(strategy.gauge(), address(0));
        assertEq(strategy.balanceOfPool(), 0);

        strategy.setGauge(AERO_USDC_GAUGE);
        assertEq(strategy.gauge(), AERO_USDC_GAUGE);
        assertEq(strategy.rewardToken(), AERO);
        assertEq(strategy.minStakeBlocks(), 7);
        assertEq(strategy.actionableBlock(), 0);
        assertTrue(strategy.actionable());

        strategy.setGauge(address(0));
        assertEq(strategy.gauge(), address(0));
    }

    function testFeeOnlyHarvestUsesPairFeeInterface() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        (uint256 pending0, uint256 pending1) = strategy.feesAvailable();
        assertEq(pending0, 0);
        assertEq(pending1, 0);

        strategy.harvest();
        assertEq(strategy.fees0(), 0);
        assertEq(strategy.fees1(), 0);
    }

    function testFeeOnlyHarvestChargesFeesAndIncludesRetainedReservesInCallReward() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        uint256 fee0 = 100 ether;
        uint256 fee1 = 100e6;
        uint256 feeRate = 0.1 ether;
        feeConfig.setFees(feeRate, 0.8 ether, 0.1 ether, 0.1 ether);
        deal(AERO, address(strategy), fee0);
        deal(USDC, address(strategy), fee1);
        // The mock swapper prices every token 1:1 for deterministic accounting.
        deal(USDC, address(swapper), fee0 * feeRate / 1 ether);
        vm.mockCall(
            AERO_USDC_PAIR,
            abi.encodeWithSelector(IAeroPair.claimFees.selector, address(strategy)),
            abi.encode(fee0, fee1)
        );
        // This test focuses on collection, fee charging, and reserve accounting;
        // the live Metarouter liquidity command is covered separately by stake tests.
        vm.mockCall(AERO_UNIVERSAL_ROUTER, abi.encodeWithSelector(IAeroRouter.execute.selector), bytes(""));

        address caller = address(0xCA11);
        strategy.harvest(caller);

        uint256 nativeEarned = fee0 * feeRate / 1 ether + fee1 * feeRate / 1 ether;
        assertEq(IERC20(USDC).balanceOf(caller), nativeEarned * 0.1 ether / 1 ether);
        assertEq(IERC20(USDC).balanceOf(STRATEGIST), nativeEarned * 0.1 ether / 1 ether);
        assertEq(IERC20(USDC).balanceOf(BEEFY_FEE_RECIPIENT), nativeEarned * 0.8 ether / 1 ether);
        assertEq(strategy.fees0(), fee0 - fee0 * feeRate / 1 ether);
        assertEq(strategy.fees1(), fee1 - fee1 * feeRate / 1 ether);

        uint256 expectedCallReward =
            (strategy.fees0() * feeRate / 1 ether + strategy.fees1() * feeRate / 1 ether) * 0.1 ether / 1 ether;
        assertEq(strategy.callReward(), expectedCallReward);
    }

    function testRewardReserveSurvivesGaugeDisableAndConvertsOnNextHarvest() public {
        StrategyAeroHarness strategy = new StrategyAeroHarness();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());
        feeConfig.setFees(0.1 ether, 0.8 ether, 0.1 ether, 0.1 ether);

        strategy.setGauge(AERO_USDC_GAUGE);
        uint256 rewards = 100 ether;
        deal(AERO, address(strategy), rewards);
        strategy.recordClaimedRewards(0);
        assertEq(strategy.rewardBalance(), rewards);

        strategy.setGauge(address(0));
        assertEq(strategy.callReward(), 1 ether);

        // 50 AERO converts into USDC, then 5 AERO of performance fees also
        // converts into USDC. The mock swapper prices both legs 1:1.
        deal(USDC, address(swapper), 55 ether);
        vm.mockCall(AERO_UNIVERSAL_ROUTER, abi.encodeWithSelector(IAeroRouter.execute.selector), bytes(""));
        strategy.harvest(address(0xCA11));

        assertEq(strategy.rewardBalance(), 0);
        assertEq(strategy.fees0(), 45 ether);
        assertEq(strategy.fees1(), 45 ether);
    }

    function testSetGaugeStakesAvailableLp() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        uint256 lpAmount = 1 ether;
        deal(AERO_USDC_PAIR, address(strategy), lpAmount);

        // `deal` bypasses the pair's LP transfer hook, so it cannot create a
        // valid fee-index checkpoint for this synthetic LP balance.
        vm.mockCall(
            AERO_USDC_PAIR,
            abi.encodeWithSelector(IAeroPair.claimFees.selector, address(strategy)),
            abi.encode(uint256(0), uint256(0))
        );
        strategy.setGauge(AERO_USDC_GAUGE);

        assertEq(strategy.balanceOfPool(), lpAmount);
        assertEq(strategy.balanceOfWant(), 0);
        assertEq(strategy.rewardToken(), AERO);
        assertEq(strategy.actionableBlock(), block.number + 7);
        assertFalse(strategy.actionable());

        vm.expectRevert(abi.encodeWithSelector(StrategyAero.ActionLocked.selector, block.number + 7));
        strategy.setGauge(address(0));
        vm.roll(block.number + 8);
        strategy.setGauge(address(0));
        assertEq(strategy.balanceOfPool(), 0);
        assertEq(strategy.balanceOfWant(), lpAmount);
    }

    function testWithdrawIsLockedWhileGaugeStakeIsInPenaltyWindow() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        uint256 lpAmount = 1 ether;
        deal(AERO_USDC_PAIR, address(strategy), lpAmount);
        vm.mockCall(
            AERO_USDC_PAIR,
            abi.encodeWithSelector(IAeroPair.claimFees.selector, address(strategy)),
            abi.encode(uint256(0), uint256(0))
        );
        strategy.setGauge(AERO_USDC_GAUGE);

        vm.expectRevert(abi.encodeWithSelector(StrategyAero.ActionLocked.selector, block.number + 7));
        strategy.withdraw(lpAmount);
    }

    function testSetGaugeRejectsANonGaugeContract() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        vm.expectRevert();
        strategy.setGauge(AERO_USDC_PAIR);
    }

    function testPanicBypassesGaugeActionDelay() public {
        StrategyAero strategy = new StrategyAero();
        strategy.initialize(AERO_USDC_PAIR, AERO_UNIVERSAL_ROUTER, USDC, _commonAddresses());

        uint256 lpAmount = 1 ether;
        deal(AERO_USDC_PAIR, address(strategy), lpAmount);
        vm.mockCall(
            AERO_USDC_PAIR,
            abi.encodeWithSelector(IAeroPair.claimFees.selector, address(strategy)),
            abi.encode(uint256(0), uint256(0))
        );
        strategy.setGauge(AERO_USDC_GAUGE);

        assertFalse(strategy.actionable());
        strategy.panic();

        assertTrue(strategy.paused());
        assertEq(strategy.balanceOfPool(), 0);
        assertEq(strategy.balanceOfWant(), lpAmount);
    }

    function _commonAddresses() private view returns (StratFeeManagerInitializable.CommonAddresses memory common) {
        common = StratFeeManagerInitializable.CommonAddresses({
            vault: address(this),
            unirouter: address(swapper),
            keeper: address(this),
            strategist: STRATEGIST,
            beefyFeeRecipient: BEEFY_FEE_RECIPIENT,
            beefyFeeConfig: address(feeConfig)
        });
    }
}
