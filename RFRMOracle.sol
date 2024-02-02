// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

/**
 * @title RFRM Oracle
 * @notice This contract provides an oracle for RFRM token prices in various currencies.
 * @dev Reform DAO
 */
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { AggregatorV3Interface } from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {
    UniswapV2OracleLibrary,
    FixedPoint
} from "@uniswap/v2-periphery/contracts/libraries/UniswapV2OracleLibrary.sol";

/**
 * @title IERC20
 * @notice Interface for ERC20 tokens
 */
interface IERC20 {
    function decimals() external view returns (uint8);
}

/**
 * @title SlidingWindowOracle
 * @notice An oracle contract that calculates the average price of an asset over a sliding time window.
 */
contract SlidingWindowOracle {
    using FixedPoint for *;

    struct Observation {
        uint256 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    // Pair contract address
    address public immutable pair;

    // The desired amount of time over which the moving average should be computed, e.g., 24 hours
    uint256 public immutable windowSize;

    // The number of observations stored for each pair, i.e., how many price observations are stored for the window.
    // As granularity increases from 1, more frequent updates are needed, but moving averages become more precise.
    uint8 public immutable granularity;

    // Time period
    uint256 public immutable periodSize;

    // Observations array
    Observation[] public pairObservations;

    // Event when price is updated.
    event PriceUpdated(uint256 timestamp);

    error InvalidGranularity();
    error InvalidWindowSize();
    error MissingHistoricalObservation();
    error ZeroAddress();

    /**
     * @dev Constructor to initialize the SlidingWindowOracle.
     * @param _windowSize The desired time window for computing the moving average.
     * @param _granularity The granularity of observations.
     * @param _pair The address of the Uniswap pair contract for the token.
     */
    constructor(uint256 _windowSize, uint8 _granularity, address _pair) {
        if (_granularity <= 1) revert InvalidGranularity();
        if ((periodSize = _windowSize / _granularity) * _granularity != _windowSize) revert InvalidWindowSize();
        windowSize = _windowSize;
        granularity = _granularity;
        pair = _pair;

        // Populate the array with empty observations
        for (uint256 i = 0; i < granularity; i++) {
            pairObservations.push();
        }
    }

    /**
     * @dev Update the oracle with the latest price observation.
     */
    function update() external {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        Observation storage observation = pairObservations[observationIndex];

        // We only want to commit updates once per period (i.e., windowSize / granularity)
        uint256 timeElapsed = block.timestamp - observation.timestamp;
        if (timeElapsed > periodSize) {
            (uint256 price0Cumulative, uint256 price1Cumulative, ) = UniswapV2OracleLibrary.currentCumulativePrices(
                address(pair)
            );
            observation.timestamp = block.timestamp;
            observation.price0Cumulative = price0Cumulative;
            observation.price1Cumulative = price1Cumulative;
        }

        emit PriceUpdated(block.timestamp);
    }

    /**
     * @dev Get the index of the observation corresponding to a given timestamp.
     * @param timestamp The timestamp for which to find the observation index.
     * @return index The index of the observation in the pairObservations array.
     */
    function observationIndexOf(uint256 timestamp) public view returns (uint8 index) {
        uint256 epochPeriod = timestamp / periodSize;
        return uint8(epochPeriod % granularity);
    }

    /**
     * @dev Get all observations stored in the pairObservations array.
     * @return observations An array of observations.
     */
    function getAllObservations() public view returns (Observation[] memory) {
        return pairObservations;
    }

    /**
     * @dev Get the first observation in the sliding time window.
     * @return firstObservation The first observation in the window.
     */
    function getFirstObservationInWindow() public view returns (Observation memory firstObservation) {
        uint8 observationIndex = observationIndexOf(block.timestamp);
        uint8 firstObservationIndex = (observationIndex + 1) % granularity;
        firstObservation = pairObservations[firstObservationIndex];
    }

    /**
     * @dev Consult the oracle for the amount out corresponding to the input amount.
     * @param tokenIn The input token address.
     * @param amountIn The input amount.
     * @param tokenOut The output token address.
     * @return amountOut The computed amount out.
     */
    function consult(address tokenIn, uint256 amountIn, address tokenOut) public view returns (uint256 amountOut) {
        Observation memory firstObservation = getFirstObservationInWindow();

        uint256 timeElapsed = block.timestamp - firstObservation.timestamp;
        if (timeElapsed > windowSize) revert MissingHistoricalObservation();

        (uint256 price0Cumulative, uint256 price1Cumulative, ) = UniswapV2OracleLibrary.currentCumulativePrices(
            address(pair)
        );
        address token0 = tokenIn < tokenOut ? tokenIn : tokenOut;

        if (token0 == tokenIn) {
            return computeAmountOut(firstObservation.price0Cumulative, price0Cumulative, timeElapsed, amountIn);
        } else {
            return computeAmountOut(firstObservation.price1Cumulative, price1Cumulative, timeElapsed, amountIn);
        }
    }

    /**
     * @dev Compute the amount out based on cumulative prices and time elapsed.
     * @param priceCumulativeStart The cumulative price at the start of the period.
     * @param priceCumulativeEnd The cumulative price at the end of the period.
     * @param timeElapsed The time elapsed in seconds.
     * @param amountIn The input amount.
     * @return amountOut The computed amount out.
     */
    function computeAmountOut(
        uint256 priceCumulativeStart,
        uint256 priceCumulativeEnd,
        uint256 timeElapsed,
        uint256 amountIn
    ) private pure returns (uint256 amountOut) {
        // Overflow is desired.
        FixedPoint.uq112x112 memory priceAverage = FixedPoint.uq112x112(
            uint224((priceCumulativeEnd - priceCumulativeStart) / timeElapsed)
        );
        amountOut = priceAverage.mul(amountIn).decode144();
    }
}

/**
 * @title RFRMOracle
 * @notice An extension of SlidingWindowOracle to provide RFRM token price conversions in different currencies.
 */
contract RFRMOracle is Ownable, SlidingWindowOracle {
    AggregatorV3Interface public priceFeed; // RFRM/ETH
    bool internal isUsingChainlink;

    IERC20 public immutable token;

    address public immutable weth;

    AggregatorV3Interface public immutable ethusd;

    AggregatorV3Interface public immutable usdcusd;

    AggregatorV3Interface public immutable usdtusd;

    event OracleChanged(address feed, bool isUsing);

    error PriceNotUpdated();

    /**
     * @dev Constructor to initialize the RFRMOracle.
     * @param _pair The address of the Uniswap pair contract for RFRM token.
     * @param _token The address of the RFRM token.
     * @param _weth The address of Wrapped Ether (WETH).
     * @param _ethusd The address of the ETH/USD Chainlink aggregator.
     * @param _usdcusd The address of the USDC/USD Chainlink aggregator.
     * @param _usdtusd The address of the USDT/USD Chainlink aggregator.
     * @param _windowSize The desired time window for computing the moving average.
     * @param _granularity The granularity of observations.
     */
    constructor(
        address _pair,
        address _token,
        address _weth,
        address _ethusd,
        address _usdcusd,
        address _usdtusd,
        uint256 _windowSize,
        uint8 _granularity
    ) SlidingWindowOracle(_windowSize, _granularity, _pair) {
        if (_pair == address(0) || _token == address(0)) revert ZeroAddress();
        weth = _weth;
        ethusd = AggregatorV3Interface(_ethusd);
        usdcusd = AggregatorV3Interface(_usdcusd);
        usdtusd = AggregatorV3Interface(_usdtusd);
        token = IERC20(_token);
    }

    /**
     * @dev Set the Chainlink aggregator and specify whether it is in use.
     * @param _feed The address of the Chainlink aggregator.
     * @param _isUsing True if Chainlink aggregator is in use, false otherwise.
     */
    function setChainlink(address _feed, bool _isUsing) external onlyOwner {
        if (_isUsing) {
            if (_feed == address(0)) revert ZeroAddress();
        }
        priceFeed = AggregatorV3Interface(_feed);
        isUsingChainlink = _isUsing;
        emit OracleChanged(_feed, _isUsing);
    }

    /**
     * @dev Get the price of RFRM token in USDC.
     * @param tokenAmount The amount of RFRM tokens to convert.
     * @return usdAmount The equivalent amount in USDC.
     */
    function getPriceInUSDC(uint256 tokenAmount) external view returns (uint256 usdAmount) {
        uint256 ethAmount = getPriceInETH(tokenAmount);
        usdAmount = convertETHToUSDC(ethAmount);
    }

    /**
     * @dev Get the price of RFRM token in USDT.
     * @param tokenAmount The amount of RFRM tokens to convert.
     * @return usdAmount The equivalent amount in USDT.
     */
    function getPriceInUSDT(uint256 tokenAmount) external view returns (uint256 usdAmount) {
        uint256 ethAmount = getPriceInETH(tokenAmount);
        usdAmount = convertETHToUSDT(ethAmount);
    }

    /**
     * @dev Convert USDC to Ether (ETH).
     * @param usdAmount The amount of USDC to convert.
     * @return ethAmount The equivalent amount in Ether.
     */
    function convertUSDCToETH(uint256 usdAmount) external view returns (uint256 ethAmount) {
        (uint80 ethRoundId, int256 ethPrice, , uint256 updatedAtEth, uint80 ethAnsweredInRound) = ethusd
            .latestRoundData();
        (uint80 usdcRoundId, int256 usdcPrice, , uint256 updatedAtUsdt, uint80 usdcAnsweredInRound) = usdcusd
            .latestRoundData();

        if (ethRoundId != ethAnsweredInRound || usdcRoundId != usdcAnsweredInRound) revert PriceNotUpdated();
        if (updatedAtEth == 0 || updatedAtUsdt == 0) revert PriceNotUpdated();
        if (ethPrice == 0 || usdcPrice == 0) revert PriceNotUpdated();

        ethAmount = (10 ** 18 * uint256(usdcPrice) * usdAmount) / (uint256(ethPrice) * 10 ** 6);
    }

    /**
     * @dev Convert USDT to Ether (ETH).
     * @param usdAmount The amount of USDT to convert.
     * @return ethAmount The equivalent amount in Ether.
     */
    function convertUSDTToETH(uint256 usdAmount) external view returns (uint256 ethAmount) {
        (uint80 ethRoundId, int256 ethPrice, , uint256 updatedAtEth, uint80 ethAnsweredInRound) = ethusd
            .latestRoundData();
        (uint80 usdtRoundId, int256 usdtPrice, , uint256 updatedAtUsdt, uint80 usdtAnsweredInRound) = usdtusd
            .latestRoundData();

        if (ethRoundId != ethAnsweredInRound || usdtRoundId != usdtAnsweredInRound) revert PriceNotUpdated();
        if (updatedAtEth == 0 || updatedAtUsdt == 0) revert PriceNotUpdated();
        if (ethPrice == 0 || usdtPrice == 0) revert PriceNotUpdated();

        ethAmount = (10 ** 18 * uint256(usdtPrice) * usdAmount) / (uint256(ethPrice) * 10 ** 6);
    }

    /**
     * @dev Convert USD to Ether (ETH).
     * @param usdAmount The amount of USD to convert (with 8 decimals).
     * @return ethAmount The equivalent amount in Ether.
     */
    function convertUSDToETH(uint256 usdAmount) external view returns (uint256 ethAmount) {
        usdAmount = usdAmount * 100; //Converting to 8 decimals
        (uint80 ethRoundId, int256 ethPrice, , uint256 updatedAtEth, uint80 ethAnsweredInRound) = ethusd
            .latestRoundData();

        if (ethRoundId != ethAnsweredInRound) revert PriceNotUpdated();
        if (updatedAtEth == 0) revert PriceNotUpdated();
        if (ethPrice == 0) revert PriceNotUpdated();

        ethAmount = (usdAmount * 10 ** 18) / uint256(ethPrice);
    }

    /**
     * @dev Get the price of RFRM token in Ether (ETH).
     * @param tokenAmount The amount of RFRM tokens to convert.
     * @return ethAmount The equivalent amount in Ether.
     */
    function getPriceInETH(uint256 tokenAmount) public view returns (uint256 ethAmount) {
        if (!isUsingChainlink) {
            ethAmount = consult(address(token), tokenAmount, weth);
        } else {
            // Price of 1 RFRM including decimals
            (uint80 roundId, int256 price, , uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
            if (roundId != answeredInRound) revert PriceNotUpdated();
            if (updatedAt == 0) revert PriceNotUpdated();
            if (price == 0) revert PriceNotUpdated();

            ethAmount = (uint256(price) * tokenAmount) / 10 ** token.decimals();
        }
    }

    /**
     * @dev Convert Ether (ETH) to USDC.
     * @param ethAmount The amount of Ether to convert.
     * @return usdAmount The equivalent amount in USDC.
     */
    function convertETHToUSDC(uint256 ethAmount) public view returns (uint256 usdAmount) {
        (uint80 ethRoundId, int256 ethPrice, , uint256 updatedAtEth, uint80 ethAnsweredInRound) = ethusd
            .latestRoundData();
        (uint80 usdcRoundId, int256 usdcPrice, , uint256 updatedAtUsdt, uint80 usdcAnsweredInRound) = usdcusd
            .latestRoundData();

        if (ethRoundId != ethAnsweredInRound || usdcRoundId != usdcAnsweredInRound) revert PriceNotUpdated();
        if (updatedAtEth == 0 || updatedAtUsdt == 0) revert PriceNotUpdated();
        if (ethPrice == 0 || usdcPrice == 0) revert PriceNotUpdated();

        // USDC has 6 decimals, ETH has 18
        usdAmount = (uint256(ethPrice) * 10 ** 6 * ethAmount) / (10 ** 18 * uint256(usdcPrice));
    }

    /**
     * @dev Convert Ether (ETH) to USDT.
     * @param ethAmount The amount of Ether to convert.
     * @return usdAmount The equivalent amount in USDT.
     */
    function convertETHToUSDT(uint256 ethAmount) public view returns (uint256 usdAmount) {
        (uint80 ethRoundId, int256 ethPrice, , uint256 updatedAtEth, uint80 ethAnsweredInRound) = ethusd
            .latestRoundData();
        (uint80 usdtRoundId, int256 usdtPrice, , uint256 updatedAtUsdt, uint80 usdtAnsweredInRound) = usdtusd
            .latestRoundData();

        if (ethRoundId != ethAnsweredInRound || usdtRoundId != usdtAnsweredInRound) revert PriceNotUpdated();
        if (updatedAtEth == 0 || updatedAtUsdt == 0) revert PriceNotUpdated();
        if (ethPrice == 0 || usdtPrice == 0) revert PriceNotUpdated();

        // USDT has 6 decimals, ETH has 18
        usdAmount = (uint256(ethPrice) * 10 ** 6 * ethAmount) / (10 ** 18 * uint256(usdtPrice));
    }
}
