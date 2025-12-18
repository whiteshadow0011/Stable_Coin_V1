//SPDX-License-Identifier:MIT

pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;

    ERC20Mock public weth;
    ERC20Mock public wbtc;

    uint256 MAX_DEPOSITE_SIZE = type(uint96).max;
    uint256 public timesMintIsCalled;

    MockV3Aggregator public ethUsdPriceFeed;

    address[] public usersWithCollateralDeposited;

    constructor(DSCEngine _dscEngine, DecentralizedStableCoin _dsc) {
        dsce = _dscEngine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    function depositeCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        // address user = users[collateralSeed % users.length];
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSITE_SIZE);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositeCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function mintDsc(uint256 amountDscToMint, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInfo(msg.sender);

        int256 maxDscToMint = (int256(collateralValueInUsd / 2)) - int256(totalDscMinted);
        // console.log("this is maxDscToMint", maxDscToMint);
        if (maxDscToMint < 0) {
            return;
        }

        amountDscToMint = bound(amountDscToMint, 0, uint256(maxDscToMint));
        // console.log("this is bound for amountOfDscToMint", amountDscToMint);
        if (amountDscToMint == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDSC(amountDscToMint);
        vm.stopPrank();
        timesMintIsCalled += 1;
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }
        dsce.redeemCollateral(address(collateral), amountCollateral);
    }

    // function updateCollateralPrice(uint96 newPrice) public{
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        }
        return wbtc;
    }
}
