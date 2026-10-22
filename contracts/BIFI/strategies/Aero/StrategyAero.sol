// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin-4/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-4/contracts/token/ERC20/utils/SafeERC20.sol";

import "../../interfaces/aero/IAeroRouter.sol";
import "../../interfaces/aero/IAeroPair.sol";
import "../../interfaces/aero/IAeroGauge.sol";
import "../../interfaces/aero/IAeroFactoryRegistry.sol";
import "../../interfaces/aero/IAeroGaugeFactory.sol";
import "../../interfaces/beefy/IBeefySwapper.sol";
import "../Common/StratFeeManagerInitializable.sol";

contract StrategyAero is StratFeeManagerInitializable {
    using SafeERC20 for IERC20;

    bytes32 private constant V2_STABLE_POOL_TYPE = 0x56325f535441424c450000000000000000000000000000000000000000000000;
    bytes32 private constant V2_VOLATILE_POOL_TYPE = 0x56325f564f4c4154494c45000000000000000000000000000000000000000000;

    // Tokens used
    address public native;
    address public rewardToken;
    address public want;
    address public lpToken0;
    address public lpToken1;

    // Third party contracts
    address public gauge;
    address public factory;
    address public aeroRouter;

    bool public stable;
    bool public harvestOnDeposit;
    uint256 public lastHarvest;
    bytes32 public poolType;
    uint256 public fees0;
    uint256 public fees1;
    uint256 public rewardBalance;
    uint256 public lastGaugeDepositBlock;

    event StratHarvest(address indexed harvester, uint256 wantHarvested, uint256 tvl);
    event Deposit(uint256 tvl);
    event Withdraw(uint256 tvl);
    event ChargedFees(uint256 callFees, uint256 beefyFees, uint256 strategistFees);
    event SetAeroRouter(address aeroRouter);
    event SetGauge(address gauge);
    event SetReward(address rewardToken);
    event ClaimedFees(uint256 fee0, uint256 fee1);
    event ClaimedRewards(uint256 rewards);
    event Harvest(uint256 fee0, uint256 fee1);

    error UnsupportedPoolType(bytes32 poolType);
    error InvalidInput();
    error ActionLocked(uint256 unlockBlock);

    function initialize(address _want, address _aeroRouter, address _native, CommonAddresses calldata _commonAddresses)
        external
        initializer
    {
        if (_aeroRouter == address(0)) revert InvalidInput();
        __StratFeeManager_init(_commonAddresses);
        want = _want;
        aeroRouter = _aeroRouter;
        native = _native;
        factory = IAeroPair(want).factory();
        poolType = IAeroPair(want).POOL_TYPE();
        if (poolType != V2_STABLE_POOL_TYPE && poolType != V2_VOLATILE_POOL_TYPE) {
            revert UnsupportedPoolType(poolType);
        }
        stable = poolType == V2_STABLE_POOL_TYPE;

        lpToken0 = IAeroPair(want).token0();
        lpToken1 = IAeroPair(want).token1();

        _giveAllowances();
    }

    // puts the funds to work
    function deposit() public whenNotPaused {
        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal > 0 && gauge != address(0)) {
            _stakeGauge(wantBal);
            emit Deposit(balanceOf());
        }
    }

    function withdraw(uint256 _amount) external {
        require(msg.sender == vault, "!vault");

        uint256 wantBal = IERC20(want).balanceOf(address(this));

        if (wantBal < _amount && gauge != address(0)) {
            _enforceActionDelay();
            _unstakeGauge(_amount - wantBal, false);
            wantBal = IERC20(want).balanceOf(address(this));
        }

        if (wantBal > _amount) {
            wantBal = _amount;
        }

        if (tx.origin != owner() && !paused()) {
            uint256 withdrawalFeeAmount = wantBal * withdrawalFee / WITHDRAWAL_MAX;
            wantBal = wantBal - withdrawalFeeAmount;
        }

        IERC20(want).safeTransfer(vault, wantBal);

        emit Withdraw(balanceOf());
    }

    function beforeDeposit() external virtual override {
        if (harvestOnDeposit) {
            require(msg.sender == vault, "!vault");
            _harvest(tx.origin);
        }
    }

    function harvest() external virtual {
        _harvest(tx.origin);
    }

    function harvest(address callFeeRecipient) external virtual {
        _harvest(callFeeRecipient);
    }

    // compounds earnings and charges performance fee
    function _harvest(address callFeeRecipient) internal whenNotPaused {
        if (gauge != address(0)) _enforceActionDelay();
        _claimEarnings();
        _convertEmissions();

        uint256 fee0 = fees0;
        uint256 fee1 = fees1;
        if (fee0 == 0 && fee1 == 0) return;

        (uint256 netFee0, uint256 netFee1) = _chargeFees(callFeeRecipient, fee0, fee1);
        fees0 = netFee0;
        fees1 = netFee1;
        if (netFee0 > 0 && netFee1 > 0) {
            (fees0, fees1) = _addLiquidity(netFee0, netFee1);
        }

        lastHarvest = block.timestamp;
        emit Harvest(netFee0, netFee1);
        emit StratHarvest(msg.sender, balanceOfWant(), balanceOf());

        deposit();
    }

    /// @dev Takes performance fees only from collected trading fees or converted emissions.
    function _chargeFees(address callFeeRecipient, uint256 _fee0, uint256 _fee1)
        internal
        returns (uint256 remaining0, uint256 remaining1)
    {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 native0;
        uint256 native1;
        (remaining0, native0) = _takeFee(lpToken0, _fee0, fees.total);
        (remaining1, native1) = _takeFee(lpToken1, _fee1, fees.total);

        uint256 nativeEarned = native0 + native1;

        uint256 callFeeAmount = nativeEarned * fees.call / DIVISOR;
        IERC20(native).safeTransfer(callFeeRecipient, callFeeAmount);

        uint256 strategistFeeAmount = nativeEarned * fees.strategist / DIVISOR;
        IERC20(native).safeTransfer(strategist, strategistFeeAmount);

        uint256 beefyFeeAmount = nativeEarned - callFeeAmount - strategistFeeAmount;
        IERC20(native).safeTransfer(beefyFeeRecipient, beefyFeeAmount);

        emit ChargedFees(callFeeAmount, beefyFeeAmount, strategistFeeAmount);
    }

    function _takeFee(address _token, uint256 _amount, uint256 _fee)
        internal
        returns (uint256 remaining, uint256 nativeEarned)
    {
        uint256 feeAmount = _amount * _fee / DIVISOR;
        remaining = _amount - feeAmount;
        if (feeAmount > 0) {
            nativeEarned = _token == native ? feeAmount : IBeefySwapper(unirouter).swap(_token, native, feeAmount);
        }
    }

    // calculate the total underlaying 'want' held by the strat.
    function balanceOf() public view returns (uint256) {
        return balanceOfWant() + balanceOfPool();
    }

    // it calculates how much 'want' this contract holds.
    function balanceOfWant() public view returns (uint256) {
        return IERC20(want).balanceOf(address(this));
    }

    // it calculates how much 'want' the strategy has working in the farm.
    function balanceOfPool() public view returns (uint256) {
        if (gauge == address(0)) return 0;
        return IAeroGauge(gauge).balanceOf(address(this));
    }

    // returns rewards unharvested
    function rewardsAvailable() public view returns (uint256) {
        uint256 rewards = rewardBalance;
        if (gauge != address(0)) rewards += IAeroGauge(gauge).earned(address(this));
        return rewards;
    }

    function feesAvailable() external view returns (uint256 fee0, uint256 fee1) {
        if (gauge == address(0)) return IAeroPair(want).pendingFees(address(this));
        return (fees0, fees1);
    }

    // native reward amount for calling harvest
    function callReward() public view returns (uint256) {
        IFeeConfig.FeeCategory memory fees = getFees();
        uint256 nativeOut = _feeToNative(lpToken0, fees0, fees.total) + _feeToNative(lpToken1, fees1, fees.total);
        if (gauge == address(0)) {
            (uint256 pending0, uint256 pending1) = IAeroPair(want).pendingFees(address(this));
            nativeOut += _feeToNative(lpToken0, pending0, fees.total) + _feeToNative(lpToken1, pending1, fees.total);
        } else {
            uint256 rewards = IAeroGauge(gauge).earned(address(this));
            if (rewards > 0) nativeOut += _feeToNative(rewardToken, rewards, fees.total);
        }
        if (rewardBalance > 0) nativeOut += _feeToNative(rewardToken, rewardBalance, fees.total);

        return nativeOut * fees.call / DIVISOR;
    }

    function setHarvestOnDeposit(bool _harvestOnDeposit) external onlyManager {
        harvestOnDeposit = _harvestOnDeposit;

        if (harvestOnDeposit) {
            setWithdrawalFee(0);
        } else {
            setWithdrawalFee(10);
        }
    }

    /// @notice Enables, replaces, or disables gauge staking.
    /// @dev A zero gauge leaves LP in the strategy to accrue trading fees only.
    function setGauge(address _gauge) external onlyOwner {
        if (_gauge == gauge) revert InvalidInput();
        if (gauge != address(0)) _enforceActionDelay();
        address newRewardToken;
        if (_gauge != address(0)) {
            _validateGauge(_gauge, aeroRouter);
            newRewardToken = _emissionToken(aeroRouter);
        }

        // Once the LP moves into a gauge, its direct pair-fee entitlement is
        // relinquished. Preserve all accrued fee-only earnings before staking.
        if (gauge == address(0) && _gauge != address(0)) _collectPairFees();

        if (gauge != address(0)) {
            _unstakeGauge(balanceOfPool(), false);
            IAeroGauge(gauge).approveForClaim(aeroRouter, false);
            IAeroGauge(gauge).setApprovalForAll(aeroRouter, false);
        }

        gauge = _gauge;
        if (newRewardToken != address(0)) _setReward(newRewardToken);
        if (gauge != address(0)) {
            // The Metarouter calls withdrawFrom/claimEmissions on behalf of the
            // strategy, so it must be explicitly authorized by the gauge.
            IAeroGauge(gauge).approveForClaim(aeroRouter, true);
            IAeroGauge(gauge).setApprovalForAll(aeroRouter, true);
            if (!paused()) _stakeGauge(balanceOfWant());
        }

        emit SetGauge(_gauge);
    }

    // called as part of strat migration. Sends all the available funds back to the vault.
    function retireStrat() external {
        require(msg.sender == vault, "!vault");

        if (gauge != address(0)) {
            _enforceActionDelay();
            _unstakeGauge(balanceOfPool(), false);
        }

        uint256 wantBal = IERC20(want).balanceOf(address(this));
        IERC20(want).transfer(vault, wantBal);
    }

    // pauses deposits and withdraws all funds from third party systems.
    function panic() public onlyManager {
        pause();
        if (gauge != address(0)) _unstakeGauge(balanceOfPool(), true);
    }

    function pause() public onlyManager {
        _pause();

        _removeAllowances();
    }

    function unpause() external onlyManager {
        _unpause();

        _giveAllowances();

        deposit();
    }

    /// @dev Adds collected V2 fees through the Metarouter and retains any
    ///      unspent amounts as the next harvest's fee reserves.
    function _addLiquidity(uint256 _fee0, uint256 _fee1) internal returns (uint256 remaining0, uint256 remaining1) {
        uint256 balance0Before = IERC20(lpToken0).balanceOf(address(this)) - _fee0;
        uint256 balance1Before = IERC20(lpToken1).balanceOf(address(this)) - _fee1;
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            IAeroRouter.AddLiquidityParams({
                factory: factory,
                tokenA: lpToken0,
                tokenB: lpToken1,
                createPool: false,
                spendA: IAeroRouter.BalanceSpend({mode: IAeroRouter.SpendMode.Amount, value: _fee0}),
                spendB: IAeroRouter.BalanceSpend({mode: IAeroRouter.SpendMode.Amount, value: _fee1}),
                payerAIsUser: true,
                payerBIsUser: true,
                amountAMin: 1,
                amountBMin: 1,
                recipient: aeroRouter,
                liquidityMin: 0
            })
        );
        IAeroRouter(payable(aeroRouter)).execute(hex"22", inputs, block.timestamp);
        remaining0 = IERC20(lpToken0).balanceOf(address(this)) - balance0Before;
        remaining1 = IERC20(lpToken1).balanceOf(address(this)) - balance1Before;
    }

    /// @dev Stakes LP from this strategy through the Metarouter.
    function _stakeGauge(uint256 _amount) internal {
        if (_amount == 0) return;

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            gauge, abi.encode(IAeroRouter.BalanceSpend({mode: IAeroRouter.SpendMode.Amount, value: _amount}), true)
        );
        IAeroRouter(payable(aeroRouter)).execute(hex"29", inputs, block.timestamp);
        lastGaugeDepositBlock = block.number;
    }

    /// @dev Unstakes LP to this strategy. Only panic accepts the gauge's early-unstake penalty.
    function _unstakeGauge(uint256 _amount, bool _allowPenalty) internal {
        if (_amount == 0) return;

        uint256 rewardBalanceBefore = _balanceOfReward();
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(gauge, abi.encode(_amount), _allowPenalty);
        IAeroRouter(payable(aeroRouter)).execute(hex"2a", inputs, block.timestamp);
        _recordClaimedRewards(rewardBalanceBefore);
        if (balanceOfPool() == 0) lastGaugeDepositBlock = 0;
    }

    /// @notice First block at which a gauge action avoids the early-emissions penalty.
    function actionableBlock() public view returns (uint256) {
        if (gauge == address(0) || lastGaugeDepositBlock == 0) return 0;
        return lastGaugeDepositBlock + minStakeBlocks();
    }

    /// @notice Whether the current gauge penalty window has elapsed.
    function actionable() external view returns (bool) {
        return block.number >= actionableBlock();
    }

    /// @notice Current gauge-specific minimum stake duration, in blocks.
    function minStakeBlocks() public view returns (uint256) {
        if (gauge == address(0)) return 0;
        IAeroGaugeFactory.PenaltyConfig memory config =
            IAeroGaugeFactory(IAeroGauge(gauge).gaugeFactory()).effectivePenaltyConfig(gauge);
        return config.penaltyRate == 0 ? 0 : config.minStakeBlocks;
    }

    function _enforceActionDelay() internal view {
        uint256 unlockBlock = actionableBlock();
        if (block.number < unlockBlock) revert ActionLocked(unlockBlock);
    }

    /// @dev Validates both sides of the V2 pool/gauge relation against the
    ///      protocol registry, as pairs do not expose a `gauge()` getter.
    function _validateGauge(address _gauge, address _aeroRouter) internal view {
        if (!IAeroGauge(_gauge).isPool()) revert InvalidInput();
        if (IAeroGauge(_gauge).stakingToken() != want) revert InvalidInput();
        if (IAeroGauge(_gauge).voter() != IAeroRouter(payable(_aeroRouter)).LEAF_VOTER()) revert InvalidInput();
        address registry = IAeroRouter(payable(_aeroRouter)).FACTORY_REGISTRY();
        if (IAeroFactoryRegistry(registry).targetToGauge(want) != _gauge) revert InvalidInput();
    }

    function _emissionToken(address _aeroRouter) internal view returns (address token) {
        token = IAeroRouter(payable(_aeroRouter)).EMISSION_TOKEN();
        if (token == address(0)) revert InvalidInput();
    }

    function _giveAllowances() internal {
        _giveAeroRouterAllowances();
        _giveSwapperAllowances();
    }

    function _removeAllowances() internal {
        _removeAeroRouterAllowances();
        _removeSwapperAllowances();
    }

    function _giveSwapperAllowances() internal {
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken0).safeApprove(unirouter, type(uint256).max);
        IERC20(lpToken1).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, type(uint256).max);
        if (rewardToken != address(0) && rewardToken != lpToken0 && rewardToken != lpToken1) {
            IERC20(rewardToken).safeApprove(unirouter, type(uint256).max);
        }
    }

    function _removeSwapperAllowances() internal {
        IERC20(lpToken0).safeApprove(unirouter, 0);
        IERC20(lpToken1).safeApprove(unirouter, 0);
        if (rewardToken != address(0) && rewardToken != lpToken0 && rewardToken != lpToken1) {
            IERC20(rewardToken).safeApprove(unirouter, 0);
        }
    }

    function _feeToNative(address _token, uint256 _amount, uint256 _fee) internal view returns (uint256) {
        uint256 feeAmount = _amount * _fee / DIVISOR;
        if (feeAmount == 0) return 0;
        return _token == native ? feeAmount : IBeefySwapper(unirouter).getAmountOut(_token, native, feeAmount);
    }

    function _claimEarnings() internal {
        if (gauge == address(0)) {
            _collectPairFees();
        } else {
            uint256 rewardBalanceBefore = _balanceOfReward();
            IAeroGauge(gauge).claimEmissions(address(this), address(this));
            _recordClaimedRewards(rewardBalanceBefore);
        }
    }

    function _collectPairFees() internal {
        (uint256 fee0, uint256 fee1) = IAeroPair(want).claimFees(address(this));
        fees0 += fee0;
        fees1 += fee1;
        if (fee0 > 0 || fee1 > 0) emit ClaimedFees(fee0, fee1);
    }

    function _convertEmissions() internal {
        uint256 _amount = rewardBalance;
        if (_amount == 0) return;
        rewardBalance = 0;
        uint256 amount0In = _amount / 2;
        uint256 amount1In = _amount - amount0In;
        uint256 fee0 = rewardToken == lpToken0 ? amount0In : _swapReward(rewardToken, lpToken0, amount0In);
        uint256 fee1 = rewardToken == lpToken1 ? amount1In : _swapReward(rewardToken, lpToken1, amount1In);
        fees0 += fee0;
        fees1 += fee1;
        emit ClaimedFees(fee0, fee1);
    }

    function _balanceOfReward() internal view returns (uint256) {
        return rewardToken == address(0) ? 0 : IERC20(rewardToken).balanceOf(address(this));
    }

    function _recordClaimedRewards(uint256 _balanceBefore) internal {
        uint256 claimed = _balanceOfReward() - _balanceBefore;
        if (claimed > 0) {
            rewardBalance += claimed;
            emit ClaimedRewards(claimed);
        }
    }

    function _swapReward(address _from, address _to, uint256 _amount) internal returns (uint256) {
        if (_amount == 0) return 0;
        return IBeefySwapper(unirouter).swap(_from, _to, _amount);
    }

    /// @dev The V2 gauge does not expose an emission-token getter. Once its
    ///      voter is matched to the Metarouter's Leaf Voter, the router's
    ///      immutable EMISSION_TOKEN is the authoritative reward token.
    function _setReward(address _rewardToken) internal {
        if (_rewardToken == rewardToken) return;
        if (!paused()) _removeSwapperAllowances();
        rewardToken = _rewardToken;
        if (!paused()) _giveSwapperAllowances();
        emit SetReward(_rewardToken);
    }

    function setAeroRouter(address _aeroRouter) external onlyOwner {
        if (_aeroRouter == address(0) || _aeroRouter == aeroRouter) revert InvalidInput();
        if (gauge != address(0)) _validateGauge(gauge, _aeroRouter);

        _removeAeroRouterAllowances();
        if (gauge != address(0)) {
            IAeroGauge(gauge).approveForClaim(aeroRouter, false);
            IAeroGauge(gauge).setApprovalForAll(aeroRouter, false);
        }

        aeroRouter = _aeroRouter;
        if (gauge != address(0)) _setReward(_emissionToken(aeroRouter));
        if (gauge != address(0)) {
            IAeroGauge(gauge).approveForClaim(aeroRouter, true);
            IAeroGauge(gauge).setApprovalForAll(aeroRouter, true);
        }
        if (!paused()) _giveAeroRouterAllowances();
        emit SetAeroRouter(_aeroRouter);
    }

    function _giveAeroRouterAllowances() internal {
        IERC20(want).safeApprove(aeroRouter, type(uint256).max);
        IERC20(lpToken0).safeApprove(aeroRouter, 0);
        IERC20(lpToken0).safeApprove(aeroRouter, type(uint256).max);
        IERC20(lpToken1).safeApprove(aeroRouter, 0);
        IERC20(lpToken1).safeApprove(aeroRouter, type(uint256).max);
    }

    function _removeAeroRouterAllowances() internal {
        IERC20(want).safeApprove(aeroRouter, 0);
        IERC20(lpToken0).safeApprove(aeroRouter, 0);
        IERC20(lpToken1).safeApprove(aeroRouter, 0);
    }
}
