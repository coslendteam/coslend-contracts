pragma solidity ^0.6.0;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";
import "./IInterestRateModel.sol";

/**
  * @title Logic for Compound's JumpRateModel Contract V2.
  * @author Compound (modified by Dharma Labs, refactored by Arr00)
  * @notice Version 2 modifies Version 1 by enabling updateable parameters.
  */
contract BaseJumpRateModel is IInterestRateModel, OwnableUpgradeSafe {
    using SafeMath for uint;

    event NewInterestParams(uint baseRatePerSecond, uint multiplierPerSecond, uint jumpmultiplierPerSecond, uint kink);

    /**
     * @notice The approximate number of seconds per year that is assumed by the interest rate model
     */
    uint public constant secondsPerYear = 31536000;

    /**
     * @notice The multiplier of utilization rate that gives the slope of the interest rate
     */
    uint public multiplierPerSecond;

    /**
     * @notice The base interest rate which is the y-intercept when utilization rate is 0
     */
    uint public baseRatePerSecond;

    /**
     * @notice The jumpMultiplierPerSecond after hitting a specified utilization point
     */
     uint public jumpMultiplierPerSecond;

    /**
     * @notice The utilization point at which the jump multiplier is applied
     */
    uint public kink;

    /**
     * @notice Update the parameters of the interest rate model (only callable by owner, i.e. Timelock)
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerSecond after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    function updateJumpRateModel(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) external {
        updateJumpRateModelInternal(baseRatePerYear, multiplierPerYear, jumpMultiplierPerYear, kink_);
    }

    /**
     * @notice Calculates the utilization rate of the market: `borrows / (cash + borrows - reserves)`
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market (currently unused)
     * @return The utilization rate as a mantissa between [0, 1e18]
     */
    function utilizationRate(uint cash, uint borrows, uint reserves) public pure returns (uint) {
        // Utilization rate is 0 when there are no borrows
        if (borrows == 0) {
            return 0;
        }

        return borrows.mul(1e18).div(cash.add(borrows).sub(reserves));
    }

    /**
     * @notice Calculates the current borrow rate per block, with the error code expected by the market
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getBorrowRateInternal(uint cash, uint borrows, uint reserves) internal view returns (uint) {
        uint util = utilizationRate(cash, borrows, reserves);

        if (util <= kink) {
            return util.mul(multiplierPerSecond).div(1e18).add(baseRatePerSecond);
        } else {
            uint normalRate = kink.mul(multiplierPerSecond).div(1e18).add(baseRatePerSecond);
            uint excessUtil = util.sub(kink);
            return excessUtil.mul(jumpMultiplierPerSecond).div(1e18).add(normalRate);
        }
    }

    /**
     * @notice Calculates the current borrow rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @return The borrow rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getBorrowRate(uint cash, uint borrows, uint reserves) external virtual override view returns (uint) {
        return getBorrowRateInternal(cash, borrows, reserves);
    }


    function getSupplyRateInternal(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) internal view returns (uint) {
        uint oneMinusReserveFactor = uint(1e18).sub(reserveFactorMantissa);
        uint borrowRate = getBorrowRateInternal(cash, borrows, reserves);
        uint rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return utilizationRate(cash, borrows, reserves).mul(rateToPool).div(1e18);
    }
    /**
     * @notice Calculates the current supply rate per block
     * @param cash The amount of cash in the market
     * @param borrows The amount of borrows in the market
     * @param reserves The amount of reserves in the market
     * @param reserveFactorMantissa The current reserve factor for the market
     * @return The supply rate percentage per block as a mantissa (scaled by 1e18)
     */
    function getSupplyRate(uint cash, uint borrows, uint reserves, uint reserveFactorMantissa) external virtual override view returns (uint) {
        return getSupplyRateInternal(cash, borrows, reserves, reserveFactorMantissa);
    }

    /**
     * @notice Internal function to update the parameters of the interest rate model
     * @param baseRatePerYear The approximate target base APR, as a mantissa (scaled by 1e18)
     * @param multiplierPerYear The rate of increase in interest rate wrt utilization (scaled by 1e18)
     * @param jumpMultiplierPerYear The multiplierPerSecond after hitting a specified utilization point
     * @param kink_ The utilization point at which the jump multiplier is applied
     */
    function updateJumpRateModelInternal(uint baseRatePerYear, uint multiplierPerYear, uint jumpMultiplierPerYear, uint kink_) internal onlyOwner {
        baseRatePerSecond = baseRatePerYear.div(secondsPerYear);
        multiplierPerSecond = (multiplierPerYear.mul(1e18)).div(secondsPerYear.mul(kink_));
        jumpMultiplierPerSecond = jumpMultiplierPerYear.div(secondsPerYear);
        kink = kink_;

        emit NewInterestParams(baseRatePerSecond, multiplierPerSecond, jumpMultiplierPerSecond, kink);
    }
}
