pragma solidity ^0.6.0;

interface IPriceOracle {

    function getUnderlyingPrice(address marketToken) external view returns (uint);
}
