//SPDX-License_Identifier:MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

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

///home/white_shadow/solidity-course/foundry-defi-stablecoin-f23/lib/openzeppelin-contracts/contracts/access/Ownable.sol
import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";


//****************************** */

//WE HAVE A PROBLEM HERE WITH THE OWNABLE CONSTRUCTOR, TAKE CARE OF IT

//****************************** */


contract  DecentralizedStableCoin is ERC20Burnable, Ownable {
    
    error DecentralizedStableCoin_MustBeMoreThanZero();
    error DecentralizedStableCoin_BurnAmountExceedsBalance();
    error DecentralizedStableCoin_NotZeroAddress();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner{
        uint256 balance = balanceOf(msg.sender);
        if(_amount <=0){
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }
        if(balance < _amount){
            revert DecentralizedStableCoin_BurnAmountExceedsBalance();
        }
        // the super keyword says "use the burn func from parent class"
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns(bool){
        if(_to == address(0)){
            revert DecentralizedStableCoin_NotZeroAddress();
        }
        if(_amount <=0){
            revert DecentralizedStableCoin_MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}