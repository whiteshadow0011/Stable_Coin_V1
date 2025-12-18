//SPDX-License-Identifier:MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.20;

// /home/white_shadow/solidity-course/foundry-defi-stablecoin-f23/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol/
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./library/OracleLib.sol";

contract DSCEngine is ReentrancyGuard {
    ////////////////
    //ERROR
    ////////////////

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAdddressesAndpriceFeedAddressesMustBeSame();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine_HealthFactorOkay();
    error DSCEngine_HealthFactorNotImproved();

    ////////////////
    //Types
    ////////////////

    using OracleLib for AggregatorV3Interface;

    /////////////////////
    //STATE VARIABLES
    /////////////////////

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% OVERCOLLATERALIZED
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address token => address priceFeed) private s_priceFeeds; //tokenToPricefeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////////
    //EVENTS
    ////////////////

    event CollateralDeposited(address indexed user, address indexed tokenAdd, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ////////////////
    //MODIFIERS
    ////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ////////////////
    //FUNCTIONS
    ////////////////

    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAdddressesAndpriceFeedAddressesMustBeSame();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////
    //EXTERNAL FUNCTIONS
    ///////////////////////

    function depositeCollateralAndMintDSC(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositeCollateral(tokenCollateralAddress, amountCollateral);
        mintDSC(amountDscToMint);
    }

    function depositeCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function redeemCollateralForDSC(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        external
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint: the amount of DSC to mint
     * @notice they must have more collateral than the minimum threshold
     */
    function mintDSC(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        //if they minted too much, like more than the collateral is worth($150 minted => $100 ETH(collateral)), we revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function burnDSC(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthfactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOkay();
        }

        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);

        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);

        _burnDsc(tokenAmountFromDebtCovered, user, msg.sender);
        uint256 endingUserHealthFactor = _healthfactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////////
    //PRIVATE AND INTERNAL VIEW FUNCTIONS
    ///////////////////////

    //1. check health factor (do they have enough collateral)
    //2. revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthfactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function _healthfactor(address user) private view returns (uint256) {
        //get total DSC minted
        //total collateral value

        (uint256 totalDscminted, uint256 collateralValueInUsd) = _getAccountInformationFromUser(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / 100;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscminted;
    }

    function calculateHealthFactor(uint256 dscToMint, address collateral, uint256 amountCollateral)
        external
        returns (uint256)
    {
        if (dscToMint == 0) return type(uint256).max;
        uint256 collateralValInUsd = getUsdValue(collateral, amountCollateral);
        return ((((collateralValInUsd * LIQUIDATION_THRESHOLD) / 100) * PRECISION) / dscToMint);
    }

    function _getAccountInformationFromUser(address user)
        private
        view
        returns (uint256 totalDscminted, uint256 collateralValueInUsd)
    {
        collateralValueInUsd = getAccountCollateralValueInUsd(user);
        return (s_dscMinted[user], collateralValueInUsd);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        if (amountCollateral <= 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    ///////////////////////////////////////
    //PUBLIC AND EXTERNAL VIEW FUNCTIONS
    //////////////////////////////////////
    function getAccountCollateralValueInUsd(address user) public view returns (uint256 tokenCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            tokenCollateralValueInUsd += getUsdValue(token, amount);
        }
        return tokenCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        return (((uint256(price)) * 1e10) * amount) / 1e18;
    }

    function getDscMintedToUser(address user) public view returns (uint256) {
        return s_dscMinted[user];
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.stalePriceCheckLatestRoundData();
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getAccountInfo(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 getAccountCollateralValueInUsd)
    {
        return _getAccountInformationFromUser(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        uint256 healthFactor = _healthfactor(user);
        return healthFactor;
    }

    function getAdditionalFeedPrecesion() external view returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecesion() external view returns (uint256) {
        return PRECISION;
    }
}
