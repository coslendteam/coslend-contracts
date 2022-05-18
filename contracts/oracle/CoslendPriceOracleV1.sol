pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "./IPriceOracle.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@chainlink/contracts/src/v0.6/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/Ownable.sol";

interface MarketTokenInterface {
    function underlying() external view returns (address);
    function symbol() external view returns (string memory);
}

interface CustomPriceInterface{
    function getPrice(address token) external view returns (uint);
}

contract CoslendPriceOracleV1 is OwnableUpgradeSafe {

    using SafeMath for uint256;

    struct PriceOracle {
        address source;
        string sourceType;
        bool available;
    }

    struct TokenConfig {
        address marketToken;
        address underlying;
        string underlyingSymbol; //example: DAI
        uint256 baseUnit; //example: 1e18
        bool fixedUsd; //if true,will return 1*e36/baseUnit
        bool nativeToken;
        PriceOracle[] oracles;
    }

    event ConfigUpdated(address marketToken, address underlying, string underlyingSymbol, uint256 baseUnit, bool fixedUsd,bool nativeToken,PriceOracle[] oracles);
    mapping(address => TokenConfig) public tokenConfigs;

    function initialize() public initializer {
        OwnableUpgradeSafe.__Ownable_init();
    }

    function getPriceOracle(address marketToken) external view returns(PriceOracle[] memory){
        return tokenConfigs[marketToken].oracles;
    }


    function getUnderlyingPrice(address marketToken) external view returns (uint){

        uint256 price = 0;
        TokenConfig memory tokenConfig = tokenConfigs[marketToken];
        if (tokenConfig.fixedUsd) {//if true,will return 1*e36/baseUnit
            price = 1;
            return price.mul(1e36).div(tokenConfig.baseUnit);
        }

        PriceOracle[] memory priceOracles = tokenConfig.oracles;
        for (uint256 i = 0; i < priceOracles.length; i++) {
            PriceOracle memory priceOracle = priceOracles[i];
            if (priceOracle.available == true) {// check the priceOracle is available

                address underlying = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
                if(!tokenConfig.nativeToken){
                    underlying = address(MarketTokenInterface(marketToken).underlying());
                } 

                if(compareStrings(priceOracle.sourceType, "Flux")){
                    price = _getFluxPriceInternal(priceOracle, tokenConfig);
                }else if(compareStrings(priceOracle.sourceType, "Custom")){
                    price = _getCustomerPriceInternal(priceOracle, tokenConfig);
                }

                if (price > 0) {
                  return price;
                }
            }
        }

        // price must bigger than 0
        require(price > 0, "price must bigger than zero");

        return 0;
    }


    function _getCustomerPriceInternal(PriceOracle memory priceOracle, TokenConfig memory tokenConfig) internal view returns (uint) {
        address source = priceOracle.source;
        CustomPriceInterface customerPriceOracle = CustomPriceInterface(source);
        uint price = customerPriceOracle.getPrice(tokenConfig.underlying);
        if (price <= 0) {
            return 0;
        } else {
            return uint(price).mul(1e28).div(tokenConfig.baseUnit);
        }
    }

    function _getFluxPriceInternal(PriceOracle memory priceOracle, TokenConfig memory tokenConfig) internal view returns (uint) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(priceOracle.source);
        (,int price,,,) = priceFeed.latestRoundData();

        if (price <= 0) {
            return 0;
        } else {//return: (price / 1e8) * (1e36 / baseUnit) ==> price * 1e28 / baseUnit
            return uint(price).mul(1e28).div(tokenConfig.baseUnit);
        }
    }

    function setTokenConfig(address marketToken, address underlying, string memory underlyingSymbol, uint256 baseUnit, bool fixedUsd, bool nativeToken,
        address[] memory sources, string[] memory sourceTypes) public onlyOwner {

        require(sources.length == sourceTypes.length, "sourceTypes.length must equal than sources.length");

        // add TokenConfig
        TokenConfig storage tokenConfig = tokenConfigs[marketToken];
        tokenConfig.marketToken = marketToken;
        tokenConfig.underlying = underlying;
        tokenConfig.underlyingSymbol = underlyingSymbol;
        tokenConfig.baseUnit = baseUnit;
        tokenConfig.fixedUsd = fixedUsd;
        tokenConfig.nativeToken = nativeToken;

        PriceOracle[] storage oracles = tokenConfig.oracles;
        if(oracles.length < sources.length){
            for(uint i = 0; i < sources.length; i++){
                oracles.push(PriceOracle({
                            source : sources[i],
                            sourceType : sourceTypes[i],
                            available : true
                            }));
            }
        }else{
            for(uint i = 0; i < sources.length; i++){
                oracles[i]=PriceOracle({
                            source : sources[i],
                            sourceType : sourceTypes[i],
                            available : true
                            });
            }
        }

        emit ConfigUpdated(marketToken, underlying, underlyingSymbol, baseUnit, fixedUsd,nativeToken,tokenConfig.oracles);

    }

    function updateTokenConfigFixedUsd(address marketToken, bool fixedUsd) public onlyOwner {
        TokenConfig storage tokenConfig = tokenConfigs[marketToken];
        require(tokenConfig.marketToken != address(0), "bad params");
        tokenConfig.fixedUsd = fixedUsd;
    }

    function updateSource(address marketToken,uint index,address source,string memory sourceType,bool available) public {
        TokenConfig storage tokenConfig = tokenConfigs[marketToken];
        PriceOracle storage priceOracle = tokenConfig.oracles[index];
        priceOracle.source =source;
        priceOracle.available = available;
        priceOracle.sourceType = sourceType;

    }


    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }


}