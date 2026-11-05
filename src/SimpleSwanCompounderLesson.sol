// SPDX-License-Identifier: MIT

// SPDX line: machine-readable license used for verification on block explorers and forkability.
// =0.8.10 pins one compile version, floating point ^0.8.10 should be used for libraries such that importers can use their own compiler version
// since 0.8.0 arithmetic is checked so no SafeMath needed, prehistoric news
pragma solidity 0.8.10;

// High yield swanUSD autocompounder (realizing APY)
// Users acquire SwanUSD, stake SwanUSD, and restake sSwanUSD to earn SWAN. Accrued SWAN will be harvested, sold, and staked into sSwanUSD again to compound rewards.
// SWAN --Curve--> WETH --Uniswap--> USDC --Sky PSM--> USDS --Monolith PSM--> swanUSD --deposit--> sSwanUSD --stake--> pool

// To call another contract you need its "shape": function names, parameter TYPES and return types. It's literally an interface you declare external functions that will be called on another contract. parameter names do not matter.
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

// interface inheritance
// sSwanUSD is an ERC-20 token AND a vault with a `deposit` function. `is IERC20` means "everything IERC20 has, plus what I add here", so one variable of type IStakedSwanUSD can call transfer, approve AND deposit.
interface IStakedSwanUSD is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

/// masterchef: stake sSwanUSD, earn SWAN over time
interface IStakingRewards {
    function balanceOf(address account) external view returns (uint256);
    function earned(address account) external view returns (uint256);
    function stake(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getReward() external;
}

/// Curve SWAN/WETH pool. Coins are referred to by index: coin(0) = WETH coin(1) = SWAN.
interface ICurvePool {
    function exchange(uint256 i, uint256 j, uint256 dx, uint256 minDy) external returns (uint256);
}

// uniswap router takes one struct to keep call sites readable and avoids compiler error with too many local variables.
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

/// Sky USDS Peg Stability Module, USDC <> USDS 1:1 swaps
interface IPsmWrapper {
    function sellGem(address usr, uint256 gemAmt) external returns (uint256 usdsOut);
}

/// Monolith's PSM: USDS <> SwanUSD 1:1 swaps
interface ILender {
    function buy(uint256 assetIn, uint256 minCoinOut) external returns (uint256 coinOut);
}


// easy: Slippage(received, minimum) tells you exactly how far off you were
// good practice overall
error NotOwner();
error Reentrancy();
error ZeroAmount();
error ZeroAddress();
error InsufficientShares();
error TransferFailed();
error Slippage(uint256 received, uint256 minimum);
error EmergencyCallFailed(bytes reason);

// contract is persistent state. 
// standard practice: types -> state var -> events -> modifier -> constructor -> external, public, internal, private view/pure functions
contract SimpleSwanCompounder {

    // struct: goups related values into one custom type this is a record of a harvest compound
    struct HarvestInfo {
        uint256 swanSold;
        uint256 sSwanUsdAdded;
        uint256 timestamp;
    }

    // constant variables are fixed at compile time and copied into the bytecode, gas efficient to do constants
    // immutable: can be assigned at deploy time in constructor
    // need to use checksummed adddresses
    // wrap contract address to point "initialize" the interface, can call it now
    // I have gone onchain and determined these addresses manually, all major models can do this for you.
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
    uint24 private constant UNISWAP_FEE = 500; // 500 = 0.05% pool tier

    // state variables and storage
    // these live in the contract's permanent STORAGE on the blockchain, writing storage is the most expensive thing a contract does (~20,000 gas for a fresh slot) and every variable starts at its zero value: address(0), 0, false.
    // `public` makes the compiler generate a getter function, so anyone can call `owner()` or `totalShares()`. private only hides a variable from OTHER CONTRACTS anyone can still read every storage slot straight from the chain. Never store secrets on-chain.
    address public owner;
    uint256 public totalShares;

    // mapping is a hash table every key starts at 0
    mapping(address => uint256) public sharesOf;
    HarvestInfo public lastHarvest;

    // 1 = unlocked, 2 = locked (see LESSON 13). Starts at 1 via the initializer.
    uint256 private locked = 1;

    // events logs
    // emit writes a log into the transaction receipt, good for frontends and block explorers, general readability and good practice
    event Deposited(address indexed user, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, uint256 amount, uint256 shares);
    event Harvested(uint256 swanSold, uint256 sSwanUsdAdded);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyExecuted(address indexed target, uint256 value, bytes data);

    // modifier is reuseable code that wraps around a function
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // reentrancy
    // the first entry sets locked = 2, and any nested call sees 2 and reverts.
    // why 1/2 and not false/true (0/1)? Changing a slot from non-zero to non-zero is cheaper than writing it from zero, so we never let it go back to 0.
    modifier nonReentrant() {
        if (locked != 1) revert Reentrancy();
        locked = 2;
        _;
        locked = 1;
    }

    // runs once on deployment
    // preapprove all token allowances in their respective contracts
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

        // transferFrom returns a bool, ignoring it is bad tokens return false instead of reverting
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

    // harvest
    //   1. claim SWAN rewards                (Swan staking pool)
    //   2. SWAN    -> WETH                   (Curve)
    //   3. WETH    -> USDC                   (Uniswap V3 router, 0.05% pool)
    //   4. USDC    -> USDS                   (Sky PSM, 1:1)
    //   5. USDS    -> swanUSD                (Monolith PSM, 1:1)
    //   6. swanUSD -> sSwanUSD, then stake   (compounding!)

    function harvest(uint256 minSwanUsdOut) external onlyOwner nonReentrant {
        STAKING.getReward();

        uint256 swanAmount = SWAN.balanceOf(address(this)); // `address(this)` = this contract
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

        // `block.timestamp` = the current block's time in seconds (Unix time).
        lastHarvest = HarvestInfo({swanSold: swanAmount, sSwanUsdAdded: newSSwanUsd, timestamp: block.timestamp});

        emit Harvested(swanAmount, newSSwanUsd);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // If something unexpected breaks (a token gets stuck, a protocol changes, someone sends the wrong token), the owner can make ANY call as this contract: `target.call{value: value}(data)`.
    function call(address target, uint256 value, bytes calldata data) external payable onlyOwner nonReentrant returns (bytes memory result) {
        if (target == address(0)) revert ZeroAddress();

        bool success;
        (success, result) = target.call{value: value}(data);
        if (!success) revert EmergencyCallFailed(result);

        emit EmergencyExecuted(target, value, data);
    }

    // view functions
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

    // homework: identify one simple yield bearing opportunity that can be autocompounded, describe the opportunity, harvest flow, and write the autocompounder.
}
