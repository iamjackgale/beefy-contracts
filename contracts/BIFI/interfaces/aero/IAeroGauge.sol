// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.9.0;

pragma solidity >=0.6.0 <0.9.0;

interface IAeroGauge {
    function deposit(uint256 _lp) external;

    function depositFor(uint256 _amount, address _owner) external;

    function withdraw(uint256 _lp) external;

    function withdrawFrom(uint256 _lp, address _account) external;

    function balanceOf(address _account) external view returns (uint256 _balance);

    function totalSupply() external view returns (uint256);

    function allowance(address _owner, address _operator) external view returns (uint256);

    function approve(address _operator, uint256 _amount) external;

    function setApprovalForAll(address _operator, bool _approved) external;

    function isApprovedForAll(address _owner, address _operator) external view returns (bool);

    function earned(address _account) external view returns (uint256);

    function rewards(address _account) external view returns (uint256 _rewards);

    function claimEmissions(address _account, address _recipient) external;

    function claimReferralEmissions(address _referral, address _recipient) external;

    function deferredEmissions(address _account) external view returns (uint256 _deferredEmissions);

    function deferredReferralEmissions(address _referral) external view returns (uint256 _deferredReferralEmissions);

    function projectedRewardPerToken() external view returns (uint256 _rewardPerToken);

    function rewardPerTokenStored() external view returns (uint256);

    function userRewardPerTokenPaid(address _account) external view returns (uint256 _userRewardPerTokenPaid);

    function lastCumulativeRewardShare() external view returns (uint256);

    function collectFees() external returns (uint256 _claimed0, uint256 _claimed1);

    function pendingFees() external view returns (uint256, uint256);

    function approveForClaim(address _operator, bool _approved) external;

    function approvedForClaim(address _account, address _operator) external view returns (bool _approved);

    function isPenaltyActive(address _account) external view returns (bool);

    function depositBlock(address _account) external view returns (uint256 _block);

    function stakingToken() external view returns (address);

    function voter() external view returns (address);

    function gaugeFactory() external view returns (address);

    function votingRewardsManager() external view returns (address);

    function isPool() external view returns (bool);

    function initialize(
        address _stakingToken,
        address _votingRewardsManager,
        bool _isPool
    ) external;
}