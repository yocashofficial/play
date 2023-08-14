// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../Common.sol";

contract Range is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _chainlinkVRF,
        bytes32 _chainlinkVRFKeyHash,
        uint64 _chainlinkVRFSubscriptionId,
        address _bankroll,
        address link_eth_feed
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_chainlinkVRF);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _chainlinkVRF;
        chainlinkVRFKeyHash = _chainlinkVRFKeyHash;
        chainlinkVRFSubscriptionId = _chainlinkVRFSubscriptionId;
    }

    struct RangeGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint32 multiplier;
        bool isOver;
    }

    mapping(address => RangeGame) rangeGames;
    mapping(uint256 => address) rangeIDs;

    event gamePlayEvent(
        address indexed playerAddress,
        uint256 wager,
        uint32 multiplier,
        address tokenAddress,
        bool isOver,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss,
        uint256 VRFFee
    );

    event gameOutcomeEvent(
        address indexed playerAddress,
        uint256 wager,
        uint256 payout,
        address tokenAddress,
        uint32 multiplier,
        uint256[] rangeOutcomes,
        uint256[] payouts,
        uint32 numGames
    );

    event gameRefundEvent(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidMultiplier(uint256 max, uint256 min, uint256 multiplier);
    error InvalidNumBets(uint256 maxNumBets);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    function gameGetState(
        address player
    ) external view returns (RangeGame memory) {
        return (rangeGames[player]);
    }

    function gamePlay(
        uint256 wager,
        uint32 multiplier,
        address tokenAddress,
        bool isOver,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        if (!(multiplier >= 10421 && multiplier <= 9900000)) {
            revert InvalidMultiplier(9900000, 10421, multiplier);
        }
        if (rangeGames[msg.sender].requestID != 0) {
            revert AwaitingVRF(rangeGames[msg.sender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _checkWager(wager, tokenAddress, multiplier);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            1000000,
            msg.sender
        );

        uint256 id = _requestRandomWords(numBets);

        rangeGames[msg.sender] = RangeGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            multiplier,
            isOver
        );
        rangeIDs[id] = msg.sender;

        emit gamePlayEvent(
            msg.sender,
            wager,
            multiplier,
            tokenAddress,
            isOver,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    function gameRefund() external nonReentrant {
        require(tx.origin == msg.sender, "no contracts refunds allowed");
        RangeGame storage game = rangeGames[msg.sender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > block.number) {
            revert BlockNumberTooLow(block.number, game.blockNumber + 200);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (rangeIDs[game.requestID]);
        delete (rangeGames[msg.sender]);

        if (tokenAddress == address(0)) {
            (bool success, ) = payable(msg.sender).call{value: wager}("");
            if (!success) {
                revert TransferFailed();
            }
        } else {
            IERC20(tokenAddress).safeTransfer(msg.sender, wager);
        }
        emit gameRefundEvent(msg.sender, wager, tokenAddress);
    }

    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) external {
        if (msg.sender != ChainLinkVRF) {
            revert OnlyCoordinatorCanFulfill(msg.sender, ChainLinkVRF);
        }
        fulfillRandomWords(requestId, randomWords);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    ) internal {
        address playerAddress = rangeIDs[requestId];
        if (playerAddress == address(0)) revert();
        RangeGame storage game = rangeGames[playerAddress];

        int256 totalValue;
        uint256 payout;
        uint32 i;
        uint256[] memory rangeOutcomes = new uint256[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        uint256 winChance = 99000000000 / game.multiplier;
        uint256 numberToRollOver = 10000000 - winChance;
        uint256 gamePayout = (game.multiplier * game.wager) / 10000;

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            rangeOutcomes[i] = randomWords[i] % 10000000;
            if (rangeOutcomes[i] >= numberToRollOver && game.isOver == true) {
                totalValue += int256(gamePayout - game.wager);
                payout += gamePayout;
                payouts[i] = gamePayout;
                continue;
            }

            if (rangeOutcomes[i] <= winChance && game.isOver == false) {
                totalValue += int256(gamePayout - game.wager);
                payout += gamePayout;
                payouts[i] = gamePayout;
                continue;
            }

            totalValue -= int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit gameOutcomeEvent(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            game.multiplier,
            rangeOutcomes,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (rangeIDs[requestId]);
        delete (rangeGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    function _checkWager(
        uint256 wager,
        address tokenAddress,
        uint256 multiplier
    ) internal view {
        uint256 maxWager = getMaxWager(tokenAddress, multiplier);
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }

    function getMaxWager(
        address tokenAddress,
        uint256 _multiplier
    ) public view returns (uint256) {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * (11000 - 10890)) / (_multiplier - 10000);
        return maxWager;
    }

    function getGameInfos()
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        address[] memory allTokens = Bankroll.viewAllowedTokens();
        address[] memory tokens = new address[](allTokens.length);
        uint256[] memory balances = new uint256[](allTokens.length);
        uint256 i = 0;

        for (i; i < allTokens.length; i++) {
            if (Bankroll.getIsTokenAllowed(allTokens[i])) {
                if (allTokens[i] != address(0)) {
                    tokens[i] = allTokens[i];
                    balances[i] = IERC20(allTokens[i]).balanceOf(
                        address(Bankroll)
                    );
                } else {
                    tokens[i] = allTokens[i];
                    balances[i] = address(Bankroll).balance;
                }
            }
        }

        return (tokens, balances);
    }
}
