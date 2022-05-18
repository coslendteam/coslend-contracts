pragma solidity 0.6.12;

interface IComptroller {

   
    function enterMarkets(address[] calldata marketTokens) external returns (uint[] memory);

    function exitMarket(address marketTokenAddress) external returns (uint);

    function mintAllowed(
        address marketToken,
        address minter,
        uint mintAmount
    ) external returns (uint);

    function mintVerify(
        address marketToken,
        address minter,
        uint mintAmount,
        uint mintTokens
    ) external;


    function redeemAllowed(
        address marketToken,
        address redeemer,
        uint redeemTokens
    ) external returns (uint);


    function redeemVerify(
        address marketToken,
        address redeemer,
        uint redeemAmount,
        uint redeemTokens
    ) external;


    function borrowAllowed(
        address marketToken,
        address borrower,
        uint borrowAmount
    ) external returns (uint);


    function borrowVerify(
        address marketToken,
        address borrower,
        uint borrowAmount
    ) external;

  
    function repayBorrowAllowed(
        address marketToken,
        address payer,
        address borrower,
        uint repayAmount
    ) external returns (uint);

   
    function repayBorrowVerify(
        address marketToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) external;

    
    function liquidateBorrowAllowed(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) external returns (uint);

   
    function liquidateBorrowVerify(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) external;

    
    function seizeAllowed(
        address marketTokenCollateral,
        address marketTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external returns (uint);

   
    function seizeVerify(
        address marketTokenCollateral,
        address marketTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) external;

    
    function transferAllowed(
        address marketToken,
        address src,
        address dst,
        uint transferTokens
    ) external returns (uint);

  
    function transferVerify(
        address marketToken,
        address src,
        address dst,
        uint transferTokens
    ) external;

    
    function liquidateCalculateSeizeTokens(
        address marketTokenBorrowed,
        address marketTokenCollateral,
        uint repayAmount
    ) external view returns (uint, uint);
}