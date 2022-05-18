pragma solidity 0.6.12;

import "./ComptrollerStorage.sol";
import "./IComptroller.sol";
import "../libs/ErrorReporter.sol";
import "../libs/Exponential.sol";
import "../token/MarketToken.sol";
import {IDistribution} from "../distribution/Distribution.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

contract Comptroller is ComptrollerStorage, IComptroller, ComptrollerErrorReporter, Exponential, OwnableUpgradeSafe {

    // @notice Emitted when an admin supports a market
    event MarketListed(MarketToken marketToken);

    // @notice Emitted when an account enters a market
    event MarketEntered(MarketToken marketToken, address account);

    // @notice Emitted when an account exits a market
    event MarketExited(MarketToken marketToken, address account);

    // @notice Emitted when close factor is changed by admin
    event NewCloseFactor(uint oldCloseFactorMantissa, uint newCloseFactorMantissa);

    // @notice Emitted when a collateral factor is changed by admin
    event NewCollateralFactor(MarketToken marketToken, uint oldCollateralFactorMantissa, uint newCollateralFactorMantissa);

    // @notice Emitted when liquidation incentive is changed by admin
    event NewLiquidationIncentive(uint oldLiquidationIncentiveMantissa, uint newLiquidationIncentiveMantissa);

    // @notice Emitted when maxAssets is changed by admin
    event NewMaxAssets(uint oldMaxAssets, uint newMaxAssets);

    // @notice Emitted when price oracle is changed
    event NewPriceOracle(IPriceOracle oldPriceOracle, IPriceOracle newPriceOracle);

    // @notice Emitted when pause guardian is changed
    event NewMaintainer(address oldMaintainer, address maintainer);

    // @notice Emitted when an action is paused globally
    event ActionPausedGlobally(string action, bool pauseState);

    // @notice Emitted when an action is paused on a market
    event ActionPaused(MarketToken marketToken, string action, bool pauseState);

    /// @notice Emitted when borrow cap for a marketToken is changed
    event NewBorrowCap(MarketToken indexed marketToken, uint newBorrowCap);

     /// @notice Emitted when mint cap for a marketToken is changed
    event NewMintCap(MarketToken indexed marketToken, uint newMintCap);

    event NewDistribution(IDistribution oldDistribution,IDistribution distribution);
   
    // closeFactorMantissa must be strictly greater than this value
    uint internal constant closeFactorMinMantissa = 0.05e18;

    // closeFactorMantissa must not exceed this value
    uint internal constant closeFactorMaxMantissa = 0.9e18;

    // No collateralFactorMantissa may exceed this value
    uint internal constant collateralFactorMaxMantissa = 0.9e18;

    // liquidationIncentiveMantissa must be no less than this value
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18;

    // liquidationIncentiveMantissa must be no greater than this value
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18;

    IDistribution public distribution;

    function initialize() public initializer {

        //setting the msg.sender as the initial owner.
        super.__Ownable_init();
    }


    /*** Assets You Are In ***/

    function enterMarkets(address[] memory marketTokens) public override(IComptroller) returns (uint[] memory)  {
        uint len = marketTokens.length;

        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            MarketToken marketToken = MarketToken(marketTokens[i]);
            results[i] = uint(addToMarketInternal(marketToken, msg.sender));
        }

        return results;
    }

   
    function addToMarketInternal(MarketToken marketToken, address borrower) internal returns (Error) {
        Market storage marketToJoin = markets[address(marketToken)];

        // market is not listed, cannot join
        if (!marketToJoin.isListed) {
            return Error.MARKET_NOT_LISTED;
        }

        // already joined
        if (marketToJoin.accountMembership[borrower] == true) {
            return Error.NO_ERROR;
        }

        // no space, cannot join
        if (accountAssets[borrower].length >= maxAssets) {
            return Error.TOO_MANY_ASSETS;
        }

        marketToJoin.accountMembership[borrower] = true;
        accountAssets[borrower].push(marketToken);

        emit MarketEntered(marketToken, borrower);

        return Error.NO_ERROR;
    }

    function exitMarket(address marketTokenAddress) external override(IComptroller) returns (uint) {
        MarketToken marketToken = MarketToken(marketTokenAddress);

        // Get sender tokensHeld and amountOwed underlying from the marketToken
        (uint oErr, uint tokensHeld, uint amountOwed,) = marketToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "exitMarket: getAccountSnapshot failed");

        // Fail if the sender has a borrow balance
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        // Fail if the sender is not permitted to redeem all of their tokens
        uint allowed = redeemAllowedInternal(marketTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(marketToken)];

        // Return true if the sender is not already ‘in’ the market
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.NO_ERROR);
        }

        // Set marketToken account membership to false
        delete marketToExit.accountMembership[msg.sender];

        // Delete marketToken from the account’s list of assets
        // load into memory for faster iteration
        MarketToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == marketToken) {
                assetIndex = i;
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(assetIndex < len);

        // copy last item in list to location of item to be removed, reduce length by 1
        MarketToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.pop();

        emit MarketExited(marketToken, msg.sender);

        return uint(Error.NO_ERROR);
    }


    function getAssetsIn(address account) external view returns (MarketToken[] memory) {
        MarketToken[] memory assetsIn = accountAssets[account];
        return assetsIn;
    }

    function checkMembership(address account, MarketToken marketToken) external view returns (bool) {
        return markets[address(marketToken)].accountMembership[account];
    }

    /*** Policy Hooks ***/

    function mintAllowed(address marketToken, address minter, uint mintAmount) external override(IComptroller) returns (uint){

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!marketTokenMintPaused[marketToken], "mint is paused");

        if (!markets[marketToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[marketToken].accountMembership[minter]) {
            require(msg.sender == marketToken, "sender must be marketToken");
            Error err = addToMarketInternal(MarketToken(msg.sender), minter);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            assert(markets[marketToken].accountMembership[minter]);
        }

        uint mintCap = mintCaps[marketToken];
        if (mintCap != 0) {
            uint totalSupply = MarketToken(marketToken).totalSupply();
            uint exchangeRate = MarketToken(marketToken).exchangeRateStored();
            (MathError mErr, uint balance) = mulScalarTruncate(Exp({mantissa : exchangeRate}), totalSupply);
            require(mErr == MathError.NO_ERROR, "balance could not be calculated");
            (MathError mathErr, uint nextTotalMints) = addUInt(balance, mintAmount);
            require(mathErr == MathError.NO_ERROR, "total mint amount overflow");
            require(nextTotalMints < mintCap, "market mint cap reached");
        }

        if (distributeRewardPaused == false) {
            distribution.distributeMintReward(marketToken, minter, false);
        }

        return uint(Error.NO_ERROR);
    }

    function mintVerify(address marketToken, address minter, uint mintAmount, uint mintTokens) external override(IComptroller) {

        //Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketToken;
        minter;
        mintAmount;
        mintTokens;

    }

    function redeemAllowed(address marketToken, address redeemer, uint redeemTokens) external override(IComptroller) returns (uint){

        require(!marketTokenRedeemPaused[marketToken], "redeem is paused");

        uint allowed = redeemAllowedInternal(marketToken, redeemer, redeemTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        if (distributeRewardPaused == false) {
            distribution.distributeRedeemReward(marketToken, redeemer, false);
        }

        return uint(Error.NO_ERROR);
    }


    function redeemAllowedInternal(address marketToken, address redeemer, uint redeemTokens) internal view returns (uint) {
        if (!markets[marketToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* If the redeemer is not 'in' the market, then we can bypass the liquidity check */
        if (!markets[marketToken].accountMembership[redeemer]) {
            return uint(Error.NO_ERROR);
        }

        /* Otherwise, perform a hypothetical liquidity check to guard against shortfall */
        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(redeemer, MarketToken(marketToken), redeemTokens, 0);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        return uint(Error.NO_ERROR);
    }

    function redeemVerify(address marketToken, address redeemer, uint redeemAmount, uint redeemTokens) external override(IComptroller) {
        //Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketToken;
        redeemer;
        redeemAmount;
        redeemTokens;
    }

    function borrowAllowed(address marketToken, address borrower, uint borrowAmount) external override(IComptroller) returns (uint) {

        // Pausing is a very serious situation - we revert to sound the alarms
        require(!marketTokenBorrowPaused[marketToken], "borrow is paused");

        if (!markets[marketToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (!markets[marketToken].accountMembership[borrower]) {

            // only marketTokens may call borrowAllowed if borrower not in market
            require(msg.sender == marketToken, "sender must be marketToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(MarketToken(msg.sender), borrower);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }

            // it should be impossible to break the important invariant
            assert(markets[marketToken].accountMembership[borrower]);
        }

        if (oracle.getUnderlyingPrice(marketToken) == 0) {
            return uint(Error.PRICE_ERROR);
        }

        uint borrowCap = borrowCaps[marketToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint totalBorrows = MarketToken(marketToken).totalBorrows();
            (MathError mathErr, uint nextTotalBorrows) = addUInt(totalBorrows, borrowAmount);
            require(mathErr == MathError.NO_ERROR, "total borrows overflow");
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint shortfall) = getHypotheticalAccountLiquidityInternal(borrower, MarketToken(marketToken), 0, borrowAmount);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.INSUFFICIENT_LIQUIDITY);
        }

        
        if (distributeRewardPaused == false) {
            distribution.distributeBorrowReward(marketToken, borrower, false);
        }

        return uint(Error.NO_ERROR);

    }

    function borrowVerify(address marketToken, address borrower, uint borrowAmount) external override(IComptroller) {
        //Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketToken;
        borrower;
        borrowAmount;
    }

    function repayBorrowAllowed(address marketToken, address payer, address borrower, uint repayAmount) external override(IComptroller) returns (uint) {

        if (!markets[marketToken].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        require(!marketTokenRepayPaused[marketToken], "repay is paused");

        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        payer;
        repayAmount;

        
        if (distributeRewardPaused == false) {
            distribution.distributeRepayBorrowReward(marketToken, borrower, false);
        }

        return uint(Error.NO_ERROR);
    }

    function repayBorrowVerify(address marketToken, address payer, address borrower, uint repayAmount, uint borrowerIndex) external override(IComptroller) {

        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketToken;
        payer;
        borrower;
        repayAmount;
        borrowerIndex;
    }

    function liquidateBorrowAllowed(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external override(IComptroller) returns (uint){

        if(liquidateWhiteAddresses.length > 0){
            bool _liquidateBorrowAllowed = false;
            for(uint i = 0; i < liquidateWhiteAddresses.length; i++){
                if(liquidator == liquidateWhiteAddresses[i]){
                    _liquidateBorrowAllowed = true;
                    break;
                }
            }
            require(_liquidateBorrowAllowed,"The liquidator is not permitted to execute.");
        }


        if (!markets[marketTokenBorrowed].isListed || !markets[marketTokenCollateral].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint shortfall) = getAccountLiquidityInternal(borrower);
        if (err != Error.NO_ERROR) {
            return uint(err);
        }
        if (shortfall == 0) {
            return uint(Error.INSUFFICIENT_SHORTFALL);
        }

        /* The liquidator may not repay more than what is allowed by the closeFactor */
        uint borrowBalance = MarketToken(marketTokenBorrowed).borrowBalanceStored(borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa : closeFactorMantissa}), borrowBalance);
        if (mathErr != MathError.NO_ERROR) {
            return uint(Error.MATH_ERROR);
        }
        if (repayAmount > maxClose) {
            return uint(Error.TOO_MUCH_REPAY);
        }

        return uint(Error.NO_ERROR);
    }

    function liquidateBorrowVerify(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external override(IComptroller) {

        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketTokenBorrowed;
        marketTokenCollateral;
        liquidator;
        borrower;
        repayAmount;
        seizeTokens;

    }

    function seizeAllowed(
        address marketTokenCollateral,
        address marketTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override(IComptroller) returns (uint){
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!seizePaused, "seize is paused");

        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        seizeTokens;

        if (!markets[marketTokenCollateral].isListed || !markets[marketTokenBorrowed].isListed) {
            return uint(Error.MARKET_NOT_LISTED);
        }

        if (MarketToken(marketTokenCollateral).comptroller() != MarketToken(marketTokenBorrowed).comptroller()) {
            return uint(Error.COMPTROLLER_MISMATCH);
        }

        
        if (distributeRewardPaused == false) {
            distribution.distributeSeizeReward(marketTokenCollateral, borrower, liquidator, false);
        }

        return uint(Error.NO_ERROR);
    }

    function seizeVerify(
        address marketTokenCollateral,
        address marketTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external override(IComptroller) {

        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketTokenCollateral;
        marketTokenBorrowed;
        liquidator;
        borrower;
        seizeTokens;
    }

    function transferAllowed(
        address marketToken,
        address src,
        address dst,
        uint transferTokens
    ) external override(IComptroller) returns (uint){
        // Pausing is a very serious situation - we revert to sound the alarms
        require(!transferPaused, "transfer is paused");

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint allowed = redeemAllowedInternal(marketToken, src, transferTokens);
        if (allowed != uint(Error.NO_ERROR)) {
            return allowed;
        }

        if (distributeRewardPaused == false) {
            distribution.distributeTransferReward(marketToken, src, dst, false);
        }

        if (!markets[marketToken].accountMembership[dst]) {
            require(msg.sender == marketToken, "sender must be marketToken");
            Error err = addToMarketInternal(MarketToken(msg.sender), dst);
            if (err != Error.NO_ERROR) {
                return uint(err);
            }
            assert(markets[marketToken].accountMembership[dst]);
        }

        return uint(Error.NO_ERROR);
    }

    function transferVerify(
        address marketToken,
        address src,
        address dst,
        uint transferTokens
    ) external override(IComptroller) {
        // Shh - currently unused. It's written here to eliminate compile-time alarms.
        marketToken;
        src;
        dst;
        transferTokens;
    }

    /*** Liquidity/Liquidation Calculations ***/

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `marketTokenBalance` is the number of marketTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint marketTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

  
    function getAccountLiquidity(address account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, MarketToken(0), 0, 0);
        return (uint(err), liquidity, shortfall);
    }


    function getAccountLiquidityInternal(address account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(account, MarketToken(0), 0, 0);
    }

    function getHypotheticalAccountLiquidity(
        address account,
        address marketTokenModify,
        uint redeemTokens,
        uint borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(account, MarketToken(marketTokenModify), redeemTokens, borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    function getHypotheticalAccountLiquidityInternal(
        address account,
        MarketToken marketTokenModify,
        uint redeemTokens,
        uint borrowAmount) internal view returns (Error, uint, uint) {

        AccountLiquidityLocalVars memory vars;
        uint oErr;
        MathError mErr;

        // For each asset the account is in
        MarketToken[] memory assets = accountAssets[account];
        for (uint i = 0; i < assets.length; i++) {
            MarketToken asset = assets[i];

            // Read the balances and exchange rate from the marketToken
            (oErr, vars.marketTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(account);
            if (oErr != 0) {// semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (Error.SNAPSHOT_ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa : markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa : vars.exchangeRateMantissa});

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(address(asset));
            if (vars.oraclePriceMantissa == 0) {
                return (Error.PRICE_ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa : vars.oraclePriceMantissa});

            // Pre-compute a conversion factor from tokens -> usd (normalized price value)
            // marketTokenPrice = oraclePrice * exchangeRate
            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumCollateral += tokensToDenom * marketTokenBalance
            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.marketTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.MATH_ERROR, 0, 0);
            }

            // Calculate effects of interacting with marketTokenModify
            if (asset == marketTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.MATH_ERROR, 0, 0);
                }
            }
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.NO_ERROR, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.NO_ERROR, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    function liquidateCalculateSeizeTokens(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        uint actualRepayAmount
    ) external override(IComptroller) view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(marketTokenBorrowed);
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(marketTokenCollateral);
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
        * Get the exchange rate and calculate the number of collateral tokens to seize:
        *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
        *  seizeTokens = seizeAmount / exchangeRate
        *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
        *
        * Note: reverts on error
        */
        uint exchangeRateMantissa = MarketToken(marketTokenCollateral).exchangeRateStored();

        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (mathErr, seizeTokens) = mulScalarTruncate(ratio, actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        return (uint(Error.NO_ERROR), seizeTokens);

    }

    /*** Admin Functions ***/

    function _setPriceOracle(IPriceOracle newOracle) public onlyOwner returns (uint) {

        // Track the old oracle for the comptroller
        IPriceOracle oldOracle = oracle;

        // Set comptroller's oracle to newOracle
        oracle = newOracle;

        // Emit NewPriceOracle(oldOracle, newOracle)
        emit NewPriceOracle(oldOracle, newOracle);

        return uint(Error.NO_ERROR);
    }


    function _setCloseFactor(uint newCloseFactorMantissa) external onlyOwner returns (uint) {

        Exp memory newCloseFactorExp = Exp({mantissa : newCloseFactorMantissa});
        Exp memory lowLimit = Exp({mantissa : closeFactorMinMantissa});
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        Exp memory highLimit = Exp({mantissa : closeFactorMaxMantissa});
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.INVALID_CLOSE_FACTOR, FailureInfo.SET_CLOSE_FACTOR_VALIDATION);
        }

        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = newCloseFactorMantissa;
        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);

        return uint(Error.NO_ERROR);
    }

    function _setCollateralFactor(MarketToken marketToken, uint newCollateralFactorMantissa) external onlyOwner returns (uint) {

        // Verify market is listed
        Market storage market = markets[address(marketToken)];
        if (!market.isListed) {
            return fail(Error.MARKET_NOT_LISTED, FailureInfo.SET_COLLATERAL_FACTOR_NO_EXISTS);
        }

        Exp memory newCollateralFactorExp = Exp({mantissa : newCollateralFactorMantissa});

        // Check collateral factor <= 0.9
        Exp memory highLimit = Exp({mantissa : collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.INVALID_COLLATERAL_FACTOR, FailureInfo.SET_COLLATERAL_FACTOR_VALIDATION);
        }

        // If collateral factor != 0, fail if price == 0
        if (newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(address(marketToken)) == 0) {
            return fail(Error.PRICE_ERROR, FailureInfo.SET_COLLATERAL_FACTOR_WITHOUT_PRICE);
        }

        // Set market's collateral factor to new collateral factor, remember old value
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = newCollateralFactorMantissa;

        // Emit event with asset, old collateral factor, and new collateral factor
        emit NewCollateralFactor(marketToken, oldCollateralFactorMantissa, newCollateralFactorMantissa);

        return uint(Error.NO_ERROR);
    }

   
    function _setMaxAssets(uint newMaxAssets) external onlyOwner returns (uint) {

        uint oldMaxAssets = maxAssets;
        maxAssets = newMaxAssets;
        emit NewMaxAssets(oldMaxAssets, newMaxAssets);

        return uint(Error.NO_ERROR);
    }

  
    function _setLiquidationIncentive(uint newLiquidationIncentiveMantissa) external onlyOwner returns (uint) {

        // Check de-scaled min <= newLiquidationIncentive <= max
        Exp memory newLiquidationIncentive = Exp({mantissa : newLiquidationIncentiveMantissa});
        Exp memory minLiquidationIncentive = Exp({mantissa : liquidationIncentiveMinMantissa});
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        Exp memory maxLiquidationIncentive = Exp({mantissa : liquidationIncentiveMaxMantissa});
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.INVALID_LIQUIDATION_INCENTIVE, FailureInfo.SET_LIQUIDATION_INCENTIVE_VALIDATION);
        }

        // Save current value for use in log
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;

        // Set liquidation incentive to new incentive
        liquidationIncentiveMantissa = newLiquidationIncentiveMantissa;

        // Emit event with old incentive, new incentive
        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, newLiquidationIncentiveMantissa);

        return uint(Error.NO_ERROR);
    }

   
    function _supportMarket(MarketToken marketToken) external onlyOwner returns (uint) {

        if (markets[address(marketToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        markets[address(marketToken)] = Market({isListed : true,  collateralFactorMantissa : 0});

        _addMarketInternal(address(marketToken));
        
        if(distribution != address(0)){
            distribution._initializeMarket(address(marketToken));
        }
        
        emit MarketListed(marketToken);

        return uint(Error.NO_ERROR);
    }

    function _addMarketInternal(address marketToken) internal onlyOwner {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != MarketToken(marketToken), "market already added");
        }
        allMarkets.push(MarketToken(marketToken));
    }

  
    function _setMarketBorrowCaps(MarketToken[] calldata marketTokens, uint[] calldata newBorrowCaps) external onlyOwner{

        uint numMarkets = marketTokens.length;
        uint numBorrowCaps = newBorrowCaps.length;

        require(numMarkets != 0 && numMarkets == numBorrowCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            borrowCaps[address(marketTokens[i])] = newBorrowCaps[i];
            emit NewBorrowCap(marketTokens[i], newBorrowCaps[i]);
        }
    }

    function _setMarketMintCaps(MarketToken[] calldata marketTokens, uint[] calldata newMintCaps) external onlyOwner {

        uint numMarkets = marketTokens.length;
        uint numMintCaps = newMintCaps.length;

        require(numMarkets != 0 && numMarkets == numMintCaps, "invalid input");

        for (uint i = 0; i < numMarkets; i++) {
            mintCaps[address(marketTokens[i])] = newMintCaps[i];
            emit NewMintCap(marketTokens[i], newMintCaps[i]);
        }
    }


    function _setMaintainer(address newMaintainer) public onlyOwner returns (uint) {

        address oldMaintainer = maintainer;
        maintainer = newMaintainer;
        emit NewMaintainer(oldMaintainer, maintainer);

        return uint(Error.NO_ERROR);
    }

    function _setMintPaused(MarketToken marketToken, bool state) public returns (bool) {
        require(markets[address(marketToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        marketTokenMintPaused[address(marketToken)] = state;
        emit ActionPaused(marketToken, "Mint", state);
        return state;
    }

    function _setBorrowPaused(MarketToken marketToken, bool state) public returns (bool) {
        require(markets[address(marketToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        marketTokenBorrowPaused[address(marketToken)] = state;
        emit ActionPaused(marketToken, "Borrow", state);
        return state;
    }

    function _setRedeemPaused(MarketToken marketToken, bool state) public returns (bool) {
        require(markets[address(marketToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        marketTokenRedeemPaused[address(marketToken)] = state;
        emit ActionPaused(marketToken, "Redeem", state);
        return state;
    }

    function _setRepayPaused(MarketToken marketToken, bool state) public returns (bool) {
        require(markets[address(marketToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        marketTokenRepayPaused[address(marketToken)] = state;
        emit ActionPaused(marketToken, "Repay", state);
        return state;
    }


    function _setTransferPaused(bool state) public returns (bool) {
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        transferPaused = state;
        emit ActionPausedGlobally("Transfer", state);
        return state;
    }

    function _setSeizePaused(bool state) public returns (bool) {
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");

        seizePaused = state;
        emit ActionPausedGlobally("Seize", state);
        return state;
    }

    function _setDistributeRewardPaused(bool state) public returns (bool) {
        require(msg.sender == maintainer || msg.sender == owner(), "only maintainer and owner can pause");
        
        distributeRewardPaused = state;
        emit ActionPausedGlobally("DistributeReward", state);
        return state;
    }

    
    function _setDistribution(IDistribution newDistribution) public onlyOwner returns (uint) {

        IDistribution oldDistribution = distribution;

        distribution = newDistribution;

        emit NewDistribution(oldDistribution, distribution);

        return uint(Error.NO_ERROR);
    }

    function _setLiquidateWhiteAddresses(address[] memory _liquidateWhiteAddresses) public onlyOwner {
        liquidateWhiteAddresses = _liquidateWhiteAddresses;
    }

    function getAllMarkets() public view returns (MarketToken[] memory){
        return allMarkets;
    }

    function isMarketListed(address marketToken) public view returns (bool){
        return markets[marketToken].isListed;
    }





}
