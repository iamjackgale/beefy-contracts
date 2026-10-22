pragma solidity >=0.6.0 <0.9.0;

interface IAeroRouter {
    enum SpendMode {
        Amount,
        Pips
    }

    struct BalanceSpend {
        SpendMode mode;
        uint256 value;
    }

    struct AddLiquidityParams {
        address factory;
        address tokenA;
        address tokenB;
        bool createPool;
        BalanceSpend spendA;
        BalanceSpend spendB;
        bool payerAIsUser;
        bool payerBIsUser;
        uint256 amountAMin;
        uint256 amountBMin;
        address recipient;
        uint256 liquidityMin;
    }

    function EMISSION_TOKEN() external view returns (address);

    function FACTORY_REGISTRY() external view returns (address);

    function ICA_ROUTER() external view returns (address);

    function IS_ROOT() external view returns (bool);

    function LEAF_VOTER() external view returns (address);

    function NATIVE_ERC20() external view returns (address);

    function NATIVE_ERC20_SCALE() external view returns (uint256);

    function RELAY_FACTORY_REGISTRY() external view returns (address);

    function STAKING_ESCROW() external view returns (address);

    function STAKING_TOKEN() external view returns (address);

    function WETH() external view returns (address);

    function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable;

    function msgSender() external view returns (address _sender);

    function onERC721Received(address, address _from, uint256 _tokenId, bytes calldata)
        external
        returns (bytes4 _selector);

    function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data) external;

    receive() external payable;
}
