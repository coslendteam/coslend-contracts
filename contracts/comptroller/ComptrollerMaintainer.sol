pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ComptrollerMaintainer is AccessControl {

    bytes32 public constant MAINTAINER = keccak256("MAINTAINER");
    address public comptroller;

    constructor(address _comptroller) public{
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        comptroller = _comptroller;
    }

    function setMintPaused(address[] memory pTokens, bool state) public {

        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        for (uint i = 0; i < pTokens.length; i++) {
            address pToken = pTokens[i];
            bytes memory payload = abi.encodeWithSignature("_setMintPaused(address,bool)", pToken, state);
            (bool success, bytes memory returnData) = address(comptroller).call(payload);
            require(success);
        }
    }

    function setBorrowPaused(address[] memory pTokens, bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        for (uint i = 0; i < pTokens.length; i++) {
            address pToken = pTokens[i];
            bytes memory payload = abi.encodeWithSignature("_setBorrowPaused(address,bool)", pToken, state);
            (bool success, bytes memory returnData) = address(comptroller).call(payload);
            require(success);
        }
    }

    function setRedeemPaused(address[] memory pTokens, bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        for (uint i = 0; i < pTokens.length; i++) {
            address pToken = pTokens[i];
            bytes memory payload = abi.encodeWithSignature("_setRedeemPaused(address,bool)", pToken, state);
            (bool success, bytes memory returnData) = address(comptroller).call(payload);
            require(success);
        }
    }

    function setRepayPaused(address[] memory pTokens, bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        for (uint i = 0; i < pTokens.length; i++) {
            address pToken = pTokens[i];
            bytes memory payload = abi.encodeWithSignature("_setRepayPaused(address,bool)", pToken, state);
            (bool success, bytes memory returnData) = address(comptroller).call(payload);
            require(success);
        }
    }

    function setTransferPaused(bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        bytes memory payload = abi.encodeWithSignature("_setTransferPaused(bool)", state);
        (bool success, bytes memory returnData) = address(comptroller).call(payload);
        require(success);
    }

    function setSeizePaused(bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        bytes memory payload = abi.encodeWithSignature("_setSeizePaused(bool)", state);
        (bool success, bytes memory returnData) = address(comptroller).call(payload);
        require(success);
    }

    function setDistributeRewardPaused(bool state) public {
        require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

        bytes memory payload = abi.encodeWithSignature("_setDistributeRewardPaused(bool)", state);
        (bool success, bytes memory returnData) = address(comptroller).call(payload);
        require(success);
    }

    function setOutPaused(address[] memory pTokens, bool state) public{
         require(hasRole(MAINTAINER, msg.sender), "Caller is not a maintainer");

         setBorrowPaused(pTokens,state);
         setRedeemPaused(pTokens,state);

    }




}
