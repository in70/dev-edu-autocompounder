// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IStakedSwanUSD is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IStakingRewards {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
}

interface ICurvePool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external returns (uint256);
}

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IPsmWrapper {
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOut);
}

interface ILender {
    function buy(uint256 assetIn, uint256 minCoinOut) external returns (uint256 coinOut);
}

error NotOwner();
error Reentrancy();
error ZeroAmount();
error ZeroAddress();
error InsufficientShares();
error TransferFailed();
error Slippage(uint256 received, uint256 minimum);
error EmergencyCallFailed(bytes reason);

contract SimpleSwanCompounder {
    struct HarvestInfo {
        uint256 swanSold;
        uint256 sSwanUsdAdded;
        uint256 timestamp;
    }

    IStakedSwanUSD public constant SSWANUSD = IStakedSwanUSD(0xfa80c7349cC2357C42A64C2954B24B1a61C29435);
    IERC20 public constant SWANUSD = IERC20(0x9BF2B2F57A2968A0E81546Ed50cBbbb7C9d6e05E);
    IERC20 public constant SWAN = IERC20(0xD0a32F6d4850F9D6DF7d4F8f84af1Fcd3Cf993CC);
    IERC20 public constant WETH = IERC20(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20 public constant USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 public constant USDS = IERC20(0xdC035D45d973E3EC169d2276DDab16f1e407384F);

    IStakingRewards public constant STAKING = IStakingRewards(0x3C3Ae3F3a645efe6299f0EDfFb3162E630Db956a);
    ICurvePool public constant CURVE_SWAN_WETH = ICurvePool(0xFFb7f90354c496210c471459133DA2E452d8138A);
    ISwapRouter public constant UNISWAP_ROUTER = ISwapRouter(0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45);
    IPsmWrapper public constant SKY_PSM = IPsmWrapper(0xA188EEC8F81263234dA3622A406892F3D630f98c);
    ILender public constant MONOLITH_PSM = ILender(0x4ed5c72816aBc1b67ac31DdAbE31cff4a8c56a15);

    uint256 private constant CURVE_WETH_INDEX = 0;
    uint256 private constant CURVE_SWAN_INDEX = 1;
    uint24 private constant UNISWAP_FEE = 500;

    address public owner;
    uint256 public totalShares;
    mapping(address => uint256) public sharesOf;
    HarvestInfo public lastHarvest;
    uint256 private locked = 1;

    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event Harvested(uint256 swanSold, uint256 sSwanUsdAdded);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyExecuted(address indexed target, uint256 value, bytes data);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    constructor() {
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        SSWANUSD.approve(address(STAKING), type(uint256).max);
        SWAN.approve(address(CURVE_SWAN_WETH), type(uint256).max);
        WETH.approve(address(UNISWAP_ROUTER), type(uint256).max);
        USDC.approve(address(SKY_PSM), type(uint256).max);
        USDS.approve(address(MONOLITH_PSM), type(uint256).max);
        SWANUSD.approve(address(SSWANUSD), type(uint256).max);
    }

    function deposit(uint256 amount) external nonReentrant returns (uint256 shares) {
        if (amount == 0) revert ZeroAmount();

        uint256 assets = totalAssets();
        shares = totalShares == 0 ? amount : (amount * totalShares) / assets;
        if (shares == 0) revert ZeroAmount();

        sharesOf[msg.sender] += shares;
        totalShares += shares;

        if (!SSWANUSD.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        STAKING.stake(amount);

        emit Deposited(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external nonReentrant returns (uint256 amount) {
        if (shares == 0 || shares > sharesOf[msg.sender]) revert InsufficientShares();

        amount = (shares * totalAssets()) / totalShares;
        if (amount == 0) revert ZeroAmount();

        sharesOf[msg.sender] -= shares;
        totalShares -= shares;

        STAKING.withdraw(amount);
        if (!SSWANUSD.transfer(msg.sender, amount)) revert TransferFailed();

        emit Withdrawn(msg.sender, amount, shares);
    }

    function harvest(uint256 minSwanUsdOut) external onlyOwner nonReentrant {
        STAKING.getReward();

        uint256 swanAmount = SWAN.balanceOf(address(this));
        if (swanAmount == 0) revert ZeroAmount();

        uint256 wethAmount = CURVE_SWAN_WETH.exchange(CURVE_SWAN_INDEX, CURVE_WETH_INDEX, swanAmount, 0);

        uint256 usdcAmount = UNISWAP_ROUTER.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(WETH),
                tokenOut: address(USDC),
                fee: UNISWAP_FEE,
                recipient: address(this),
                amountIn: wethAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 usdsAmount = SKY_PSM.sellGem(address(this), usdcAmount);

        uint256 swanUsdAmount = MONOLITH_PSM.buy(usdsAmount, 0);
        if (swanUsdAmount < minSwanUsdOut) revert Slippage(swanUsdAmount, minSwanUsdOut);

        uint256 newSSwanUsd = SSWANUSD.deposit(swanUsdAmount, address(this));
        STAKING.stake(newSSwanUsd);

        lastHarvest = HarvestInfo({swanSold: swanAmount, sSwanUsdAdded: newSSwanUsd, timestamp: block.timestamp});

        emit Harvested(swanAmount, newSSwanUsd);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function emergencyExecute(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        if (target == address(0)) revert ZeroAddress();

        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert EmergencyCallFailed(result);

        emit EmergencyExecuted(target, value, data);
    }

    function totalAssets() public view returns (uint256) {
        return STAKING.balanceOf(address(this));
    }

    function assetsOf(address user) external view returns (uint256) {
        if (totalShares == 0) return 0;
        return (sharesOf[user] * totalAssets()) / totalShares;
    }

    function pendingSwan() external view returns (uint256) {
        return STAKING.earned(address(this));
    }
}
