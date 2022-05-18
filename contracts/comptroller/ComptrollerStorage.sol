pragma solidity 0.6.12;

import "../oracle/IPriceOracle.sol";
import "../token/MarketToken.sol";

contract ComptrollerStorage {

    /**
     * @notice Oracle which gives the price of any given asset
     */
    IPriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint256 public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint256 public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint256 public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => MarketToken[]) public accountAssets;

    struct Market {
        // @notice Whether or not this market is listed
        bool isListed;

        // @notice Multiplier representing the most one can borrow against their collateral in this market.
        // For instance, 0.9 to allow borrowing 90% of collateral value. Must be between 0 and 1, and stored as a mantissa.
        uint256 collateralFactorMantissa;

        // @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;

    }

    /**
     * @notice Official mapping of marketTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     *  Actions which allow users to remove their own assets cannot be paused.
     *  Liquidation / seizing / transfer can only be paused globally, not by market.
     */
    bool public mintPaused;
    bool public redeemPaused;
    bool public borrowPaused;
    bool public repayPaused;
    bool public transferPaused;
    bool public seizePaused;
    bool public distributeRewardPaused;

    mapping(address => bool) public marketTokenMintPaused;
    mapping(address => bool) public marketTokenRedeemPaused;
    mapping(address => bool) public marketTokenBorrowPaused;
    mapping(address => bool) public marketTokenRepayPaused;

    mapping(address => uint256) public borrowCaps;
    mapping(address => uint256) public mintCaps;

    /// @notice A list of all markets
    MarketToken[] public allMarkets;

    address public maintainer; 

    address[] public liquidateWhiteAddresses;

}
