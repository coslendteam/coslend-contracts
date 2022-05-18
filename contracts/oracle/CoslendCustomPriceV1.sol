pragma solidity 0.6.12;

import "@openzeppelin/contracts-ethereum-package/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts-ethereum-package/contracts/access/AccessControl.sol";

contract CoslendCustomPriceV1 is AccessControlUpgradeSafe {

    using SafeMath for uint256;

    struct Datum {
        uint256 timestamp;
        uint256 value;
    }

    struct TokenConfig {
        address token;
        string symbol;
        bool active;
    }

    mapping(address => Datum) private data;
    mapping(address => TokenConfig) public configs;

    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice The event emitted when the stored price is updated
    event PriceUpdated(address token, uint price);
    event ConfigUpdated(address token, string symbol, bool active);

    function initialize() public initializer {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function getPrice(address token) external view returns (uint){
        Datum storage datum = data[token];
        return datum.value;
    }

    function setPrice(address token, uint price) external {
        require(hasRole(REPORTER_ROLE, msg.sender), "Caller is not a REPORTER");

        _setPrice(token, price);
        emit PriceUpdated(token, price);
    }


    function setPrices(address[] calldata tokens, uint[] calldata prices) external {

        require(hasRole(REPORTER_ROLE, msg.sender), "Caller is not a REPORTER");
        require(tokens.length == prices.length, "bad params");

        for (uint i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            uint price = prices[i];

            _setPrice(token, price);
            emit PriceUpdated(token, price);
        }

    }

    function _setPrice(address token, uint price) internal {

        require(configs[token].token == token,"error token");
        require(configs[token].active,"no active");

        Datum storage datum = data[token];
        datum.value = price;
        datum.timestamp = block.timestamp;
    }

    function setTokenConfig(address token, string memory symbol,bool active) public {

        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not a ADMIN");

        TokenConfig storage config = configs[token];

        config.token = token;
        config.symbol = symbol;
        config.active = active;

        emit ConfigUpdated(token, symbol, active);

    }

}
