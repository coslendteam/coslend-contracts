pragma solidity ^0.6.0;

import "./BaseJumpRateModel.sol";


contract JumpRateModel is BaseJumpRateModel {

    function initialize(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) public initializer {
        super.__Ownable_init();
        super.updateJumpRateModelInternal(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
    }
}
