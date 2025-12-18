//SPDX-Licence-Identifier: MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {deployDsc} from "../../script/DeployDSC.s.sol";
import {Helperconfig} from "../../script/Helperconfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
// import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";

contract DSCEngineTest is Test {
    deployDsc deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    Helperconfig config;
    address wethUsdPriceFeed;
    address weth;
    address wbtcPriceFeed;

    address public USER = makeAddr("user");
    address public USER1 = makeAddr("user1");
    uint256 public AMOUNT_COLLATERAL = 10e18;
    uint256 public STARTING_ERC20_BALANCE = 10e18;
    uint256 public AMOUNT_DSC = 10;

    event CollateralDeposited(address indexed user, address indexed tokenAdd, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );
    event dscMinted(uint256 indexed amountMinted);

    function setUp() public {
        deployer = new deployDsc();
        (dsc, dsce, config) = deployer.run();
        (wethUsdPriceFeed, wbtcPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(USER1, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    ////Constructors Tests
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevrtIfTokenLengthDoesntMatchPriceFeed() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(wethUsdPriceFeed);
        priceFeedAddresses.push(wbtcPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAdddressesAndpriceFeedAddressesMustBeSame.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    ///////////////////////
    ////PriceFeed Tests
    ///////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////////
    ////DepositeCollateral Tests
    ///////////////////////////////

    function testRevertIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositeCollateral(weth, 0);
        vm.stopPrank();
    }

    function testMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateral(weth, 5);

        dsce.mintDSC(AMOUNT_DSC);
        uint256 dscminted = dsce.getDscMintedToUser(address(USER));
        assertEq(AMOUNT_DSC, dscminted);
        vm.stopPrank();
    }

    function testRevertWithUapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositeCollateral(address(ranToken), 5);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositeCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInfo(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositeAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositeAmount);
    }

    function testCanDepositCollateralWithoutMinting() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDSC(AMOUNT_DSC);
        (uint256 totalDscminted, uint256 collateralValueInUsd) = dsce.getAccountInfo(USER);
        vm.stopPrank();
        assertEq(totalDscminted, AMOUNT_DSC);
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedDepositedAmount, AMOUNT_COLLATERAL);
    }

    // function testRevertIfTransferFromFails() public {
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
    //     tokenAddresses = [address(mockCollateralToken)];
    //     feedAddresses = [ethUsdPriceFeed];

    //     vm.prank(owner);
    //     DSCEngine mockDsce= new DSCEngine(tokenAddresses, feedAddresses, address(dsc));
    //     mockCollateralToken.mint(user, amount);
    //     vm.startPrank(owner);

    //     vm.expectRevert();
    //     mockDsce.depositeCollateral();
    //     vm.stopPrank();
    // }

    // function testDepositeCollateralEmits() public{
    //     vm.expectEmit(true, true, true, false, address(dsce));
    //     emit CollateralDeposited(USER, 0x90193C961A926261B756D1E5bb255e67ff9498A1, AMOUNT_COLLATERAL);
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositeCollateral(weth, AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    // }

    //////////////////////////////////////
    ////DepositeCollateral&MintDsc Tests
    /////////////////////////////////////

    function testTransfersCollateralFromUser() public depositedCollateral {
        uint256 userBalance = IERC20(weth).balanceOf(USER);
        uint256 dsceBalance = IERC20(weth).balanceOf(address(dsce));
        console.log(userBalance);
        console.log(dsceBalance);

        assert(userBalance < dsceBalance);
    }

    function testRevertIfZeroMintDsc() public depositedCollateral {
        vm.expectRevert();
        dsce.mintDSC(0);
    }

    function testAmountDscIncreasesAfterMint() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDSC(2e18);
        uint256 mintedDsc = dsce.getDscMintedToUser(USER);
        emit dscMinted(mintedDsc);

        assertEq(mintedDsc, 2e18);
        vm.stopPrank();
    }

    function testDepositeCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateral(weth, 5e18);
        uint256 contractBalance = IERC20(weth).balanceOf(address(dsce));
        uint256 userBalance = IERC20(weth).balanceOf(USER);
        assertEq(userBalance, AMOUNT_COLLATERAL - 5e18);
        assertEq(contractBalance, AMOUNT_COLLATERAL - 5e18);
        dsce.mintDSC(2e18);
        uint256 userDscBalance = dsce.getDscMintedToUser(USER);
        assertEq(userDscBalance, 2e18);
        vm.stopPrank();
    }

    function testCalculateHealthFactor() public {
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(AMOUNT_DSC, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, AMOUNT_DSC);
        uint256 realHealthFactor = dsce.getHealthFactor(USER);
        (uint256 totalDscMinted, uint256 getAccountCollateralValueInUsd) = dsce.getAccountInfo(USER);
        console.log("realhealthFactor", realHealthFactor);
        console.log("expectedHealthFactor", expectedHealthFactor);
        vm.stopPrank();
        assertEq(expectedHealthFactor, realHealthFactor);
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(wethUsdPriceFeed).latestRoundData();
        uint256 amountToMint =
            (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecesion())) / dsce.getPrecesion();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        uint256 expectedHealthFactor = dsce.calculateHealthFactor(10001e18, weth, AMOUNT_COLLATERAL);
        vm.expectRevert();
        dsce.depositeCollateralAndMintDSC(weth, AMOUNT_COLLATERAL, 10001e18);
        vm.stopPrank();
    }

    /////////////////
    ////MintDsc
    /////////////////

    function testRevertIfMintFails() public {
        
    }

    //////////////////////////////////////
    ////RedeemCollateral and Burn DSC Tests
    /////////////////////////////////////

    function testRedeemCollateralRevertsIfAmountIsZero() public depositedCollateralAndMintDsc(USER) {
        vm.expectRevert();
        dsce.redeemCollateral(weth, 2e18);
    }

    function testRedeemCollateralRevertIfCollateralZero() public {
        vm.expectRevert();
        dsce.redeemCollateral(weth, 2e18);
    }

    function testBurnDscRevertIfDscIsZero() public depositedCollateral {
        vm.expectRevert();
        dsce.burnDSC(2e18);
    }

    //////////////////////////////
    ////Liquidate Tests
    //////////////////////////////

    modifier depositedCollateralAndMintDsc(address user) {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositeCollateral(weth, AMOUNT_COLLATERAL);
        dsce.mintDSC(1e18);
        vm.stopPrank();
        _;
    }

    // function testLiquidate() public depositedCollateralAndMintDsc(USER){
    //     vm.startPrank(USER1);
    //     ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
    //     dsce.depositeCollateral(weth, AMOUNT_COLLATERAL);
    //     dsce.mintDSC(2e18);
    //     dsce.liquidate(weth, USER, )
    //     vm.stopPrank();
    // }
}
