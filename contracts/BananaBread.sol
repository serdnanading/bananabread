// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.6.0 <0.7.0;

import "github.com/smartcontractkit/chainlink/evm-contracts/src/v0.6/ChainlinkClient.sol";
import { IERC20, ILendingPool, IProtocolDataProvider, IStableDebtToken, IAaveProtocolDataProvider, IDebtToken, ILendingPoolAddressesProvider } from './Interfaces.sol';
import { SafeERC20, DataTypes } from './Libraries.sol';
import {SafeMath} from './SafeMath.sol';
import {BananaDebtToken} from './BananaDebtToken.sol';

contract BananaBread {
  using SafeERC20 for IERC20;
  using SafeMath for uint256;

  ILendingPool constant lendingPool = ILendingPool(address(0x9FE532197ad76c5a68961439604C037EB79681F0)); // Kovan
  IProtocolDataProvider constant dataProvider = IProtocolDataProvider(address(0x744C1aaA95232EeF8A9994C4E0b3a89659D9AB79)); // Kovan
  BananaDebtToken constant bananaDebt = BananaDebtToken(address(0x41a91eaE0BF431cf187F96BadE3666f81f7fD9a5));
  TransactionRetriever constant transactionRetriever = TransactionRetriever(address(0x2c8AB682679b76d0c23B06aA4e14CAca99e6BcC6));

  address constant daiAddress = address(0xFf795577d9AC8bD7D90Ee22b6C1703490b6512FD);

  uint256 internal constant WAD_RAY_RATIO = 1e9;
  uint256 internal constant SCALE = 10^27;

  uint256 internal constant CO_SIGNER_STABLE_RATE_MULTIPLIER = 2;

  event CoSignment(address cosigner, address borrower, int amount);

  struct coSignment {
      address cosigner;
      address borrower;
      uint256 depositTime;
      uint256 interest;
      uint256 amount;
      uint256 coSignerRating;
  }

  struct transaction {
      address from;
      address to;
      int amount;
  }

  struct deposit {
      address from;
      uint256 amount;
      uint256 depositTime;
      uint256 interest;
  }

  address public stableCoinAddress;
  uint256 public amount;

  mapping(address => coSignment) public coSignerDestination;
  mapping(address => transaction[]) public pastTransactions;

  mapping(address => coSignment[]) public pastCoSignments;
  mapping(address => uint256) public pastSuccessfulTransactions;
  mapping(address => uint256) public pastUnsuccessfulTransactions;


  mapping(address => deposit) private depositedAmount;

  address[] private lenders;

  constructor() public {

  }

  function callBananaBread(address lendee, address cosigner, uint256 amount) private {
      bananaDebt.mintDebt(lendee, cosigner, amount);
  }

  function depositToPool(address depositor, uint256 amount) private {
      IERC20(daiAddress).safeTransferFrom(msg.sender, address(this), amount);
      uint256 lendingRate = getStableRate();
      depositedAmount[depositor] = deposit(depositor, amount, block.timestamp, lendingRate);
      lenders.push(depositor);
  }

  function getDepositedAmount(address depositor) private view returns (uint256){
      return depositedAmount[depositor].amount;
  }

  function getCoSignerScore(address coSigner) public view returns (uint256) {
      uint256 pastTransactionScore = getPastTransactionScore(coSigner);
      uint256 pastCoSignmentScore = getPastCoSignmentScore(coSigner);
      uint256 currentBalanceScore = getCurrentBalanceScore(coSigner);

      if(pastTransactionScore < 200){
          return pastTransactionScore / 3;
      } else if(pastCoSignmentScore < 200){
          return pastCoSignmentScore / 3;
      } else if(currentBalanceScore < 200){
          return currentBalanceScore / 3;
      }
      return (pastTransactionScore + pastCoSignmentScore + currentBalanceScore) / 3;
  }

  // Cosign a loan
  function coSign(address coSigner, uint256 amount, int duration, address borrower) public {
      // Need to meet minimum threshold
      uint256 coSignerRating = getCoSignerScore(coSigner);
      if(coSignerRating > 500) {
          // Minimum amount has to have been assigned as collateral
          uint256 minimumAmount = amount / 4;
          if(doesCoSignerHaveEnoughCollateralAssigned(coSigner, borrower, minimumAmount)) {
              // Is there enough liquidity
              uint256 poolValue = amount - minimumAmount;
              if(IERC20(daiAddress).balanceOf(address(this)) > poolValue) {
                uint256 currentTime = block.timestamp;
                uint256 interestRate = getCoSignerLendingRate();

                coSignerDestination[borrower] = coSignment(coSigner, borrower, currentTime, interestRate, amount, coSignerRating);

                lendingPool.borrow(daiAddress, minimumAmount, 1, 0, borrower);
                IERC20(daiAddress).safeTransferFrom(address(this), borrower, poolValue);
              }
          }
      }
  }

  // Get the currently accumulated interest
  function accummulatedInterest(address borrower) view public returns (uint256) {
      coSignment memory runningBalance = coSignerDestination[borrower];
      uint256 startingDays = runningBalance.depositTime / 1 days;
      uint256 currentDays = block.timestamp / 1 days;
      uint256 accumulatedDays = currentDays - startingDays;
      uint256 accumulatedInterest = runningBalance.interest / 30 * accumulatedDays;
      return accumulatedInterest;
  }

  // Borrower can pay off the loan
  function payOffLoan(address borrower, uint256 amount) public {
      IERC20(daiAddress).safeTransferFrom(borrower, address(this), amount);
      coSignment memory runningBalance = coSignerDestination[borrower];

      uint256 newBalance = totalOutstanding(borrower) - amount;
      if(newBalance == 0) {
          delete coSignerDestination[borrower];
          uint256 oldCosignmentCount = pastSuccessfulTransactions[runningBalance.cosigner];

          pastSuccessfulTransactions[runningBalance.cosigner] = oldCosignmentCount + 1;
      } else {
          runningBalance.amount = newBalance;
      }
  }

  // What is the total outstanding debt for borrower
  function totalOutstanding(address borrower) public view returns (uint256){
      uint256 totalInterest = accummulatedInterest(borrower);
      coSignment memory runningBalance = coSignerDestination[borrower];

      // 4 DC points
      uint256 dcInterest = totalInterest / 10^23;

      uint256 extraPayment = runningBalance.amount * dcInterest / 10^4;
      return extraPayment + runningBalance.amount;
  }

  // Redeem the lent assets
  function redeemAsLender(address lender) public {
      uint256 depositedVal = depositedAmount[lender].amount;
      require(depositedVal != 0);
      uint256 accumulatedInterest = getLenderAccumulatedInterest(lender);
      uint256 accumulatedAmount = getLenderAccumulatedFunds(depositedVal, accumulatedInterest);

      delete depositedAmount[lender];
      IERC20(daiAddress).approve(lender, accumulatedAmount);
      IERC20(daiAddress).safeTransferFrom(address(this), lender, accumulatedAmount);
  }

  function getLenderAccumulatedInterest(address lender) public view returns (uint256) {
      deposit memory depositedFunds = depositedAmount[lender];

      uint256 startingDays = depositedFunds.depositTime / 1 days;
      uint256 currentDays = block.timestamp / 1 days;
      uint256 accumulatedDays = currentDays - startingDays;
      uint256 accumulatedInterest = depositedFunds.interest / 30 * accumulatedDays;

      return accumulatedInterest;
  }

  function getLenderAccumulatedFunds(uint256 amount, uint256 interest) public view returns (uint256) {
      // 4 DC points
      uint256 dcInterest = interest / 10^23;

      uint256 extraPayment = amount * dcInterest / 10^4;
      return extraPayment + amount;
  }

  function doesCoSignerHaveEnoughCollateralAssigned(address coSigner, address borrowerAddress, uint256 requiredCollateral) public view returns(bool) {
      // Get the Protocol Data Provider
      IAaveProtocolDataProvider provider = IAaveProtocolDataProvider(address(0x3c73A5E5785cAC854D468F727c606C07488a29D6));

      // Get the relevant debt token address
      (, address stableDebtTokenAddress, ) = provider.getReserveTokensAddresses(daiAddress);

      // For stable debt tokens
      uint256 stableAllowance = IDebtToken(stableDebtTokenAddress).borrowAllowance(coSigner, borrowerAddress);
      return stableAllowance > requiredCollateral;
  }

  function getStableRate() public view returns (uint256){
      (,,,,, uint256 stableBorrowRate,,,,) = dataProvider.getReserveData(daiAddress);

      return stableBorrowRate;
  }

  function getCoSignerLendingRate() public view returns (uint256){
      uint256 coSignerLendingRate = getStableRate();
      uint256 coSignerScore = getCoSignerScore(address(0x693634C21111C729fae672C0Cfc2C85dE81e4D57));

      uint256 multiplier = 1000 - coSignerScore;

      uint256 tempVal = multiplier + 1000;
      uint256 tempVal2 = coSignerLendingRate / 1000;

      return tempVal2 * tempVal;
  }

  function getPastTransactions(address coSigner) private view returns (transaction[] memory){
      return pastTransactions[coSigner];
  }

  function getPastCoSignmentDeals(address coSigner) private view returns (coSignment[] memory){
      return pastCoSignments[coSigner];
  }


  function setUpDataCoSigner(address coSigner) public {
      transactionRetriever.requestTransactionScore(coSigner);
  }

  function getPastTransactionScore(address coSigner) private view returns (uint256) {
      return transactionRetriever.getRating(coSigner);
  }

  function getPastCoSignmentScore(address coSigner) private view returns(uint256) {
      uint256 pastSuccessfulTransactionsCount = pastSuccessfulTransactions[coSigner];
      uint256 pastUnsuccessfulTransactionsCount = pastUnsuccessfulTransactions[coSigner];

      if(pastUnsuccessfulTransactionsCount > 3) {
          return 0;
      }
      uint256 transactionCountDiff = pastSuccessfulTransactionsCount - pastUnsuccessfulTransactionsCount;
      uint256 diffFromBase = transactionCountDiff + 5;
      if(diffFromBase > 10){
          return 1000;
      }
      return diffFromBase * 100;
  }

  function getCurrentBalanceScore(address coSigner) public view returns(uint256) {
      uint256 currentBalance = IERC20(daiAddress).balanceOf(coSigner);
      uint256 divider = 1000000000000000000;
      uint256 balanceInDai = currentBalance / divider;

      uint256 maxBalance = 1000;
      if(balanceInDai < 1000) {
          maxBalance = balanceInDai;
      }
      return maxBalance;
  }
}

contract TransactionRetriever is ChainlinkClient {
    // Stores the answer from the Chainlink oracle
  address public owner;

  uint256 private rating;

    // The address of an oracle - you can find node addresses on https://market.link/search/nodes
  address ORACLE_ADDRESS = 0x56dd6586DB0D08c6Ce7B2f2805af28616E082455;

  // The address of the http get job - you can find job IDs on https://market.link/search/jobs
  string constant JOBID = "b6602d14e4734c49a5e1ce19d45a4632";

  // 17 0s = 0.1 LINK
  // 18 0s = 1 LINK
  uint256 constant private ORACLE_PAYMENT = 100000000000000000;

  constructor() public {
    // Set the address for the LINK token for the network
    setPublicChainlinkToken();
    owner = msg.sender;
  }

  function requestTransactionScore(address coSigner) public
  {
    Chainlink.Request memory req = buildChainlinkRequest(stringToBytes32(JOBID), address(this), this.fulfill.selector);
    string memory callAddress = "https://a861aff8edfa.ngrok.io/transactions";
    req.add("get", callAddress);
    sendChainlinkRequestTo(ORACLE_ADDRESS, req, ORACLE_PAYMENT);
  }

  function getRating(address coSigner) view public returns(uint256){
      return rating;
  }

  // fulfill receives a uint256 data type
  function fulfill(bytes32 _requestId, uint256 _rating) public recordChainlinkFulfillment(_requestId)
  {
    rating = _rating;
  }

  // cancelRequest allows the owner to cancel an unfulfilled request
  function cancelRequest(
    bytes32 _requestId,
    uint256 _payment,
    bytes4 _callbackFunctionId,
    uint256 _expiration
  )
    public
    onlyOwner
  {
    cancelChainlinkRequest(_requestId, _payment, _callbackFunctionId, _expiration);
  }


  // withdrawLink allows the owner to withdraw any extra LINK on the contract
  function withdrawLink()
    public
    onlyOwner
  {
    LinkTokenInterface link = LinkTokenInterface(chainlinkTokenAddress());
    require(link.transfer(msg.sender, link.balanceOf(address(this))), "Unable to transfer");
  }

  modifier onlyOwner() {
    require(msg.sender == owner);
    _;
  }

   // A helper funciton to make the string a bytes32
  function stringToBytes32(string memory source) private pure returns (bytes32 result) {
    bytes memory tempEmptyStringTest = bytes(source);
    if (tempEmptyStringTest.length == 0) {
      return 0x0;
    }
    assembly {
      result := mload(add(source, 32))
    }
  }
}
