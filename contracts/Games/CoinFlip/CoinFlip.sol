// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "../Common.sol";

contract CoinFlip is Common {
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

    struct CoinFlipGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        bool isHeads;
    }

    mapping(address => CoinFlipGame) coinFlipGames;
    mapping(uint256 => address) coinIDs;

    event gamePlayEvent(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        bool isHeads,
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
        uint8[] coinOutcomes,
        uint256[] payouts,
        uint32 numGames
    );

    event gameRefundEvent(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    function gameGetState(
        address player
    ) external view returns (CoinFlipGame memory) {
        return (coinFlipGames[player]);
    }

    function gamePlay(
        uint256 wager,
        address tokenAddress,
        bool isHeads,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        address msgSender = msg.sender;
        if (coinFlipGames[msgSender].requestID != 0) {
            revert AwaitingVRF(coinFlipGames[msgSender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _checkWager(wager, tokenAddress);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            1000000,
            msgSender
        );

        uint256 id = _requestRandomWords(numBets);

        coinFlipGames[msgSender] = CoinFlipGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            isHeads
        );
        coinIDs[id] = msgSender;

        emit gamePlayEvent(
            msgSender,
            wager,
            tokenAddress,
            isHeads,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    function gameRefund() external nonReentrant {
        require(tx.origin == msg.sender, "no contracts refunds allowed");
        CoinFlipGame storage game = coinFlipGames[msg.sender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 2010 > block.number) {
            revert BlockNumberTooLow(block.number, game.blockNumber + 2010);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (coinIDs[game.requestID]);
        delete (coinFlipGames[msg.sender]);

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
        address playerAddress = coinIDs[requestId];
        if (playerAddress == address(0)) revert();
        CoinFlipGame storage game = coinFlipGames[playerAddress];
        if (block.number > game.blockNumber + 2000) revert();

        int256 totalValue;
        uint256 payout;
        uint32 i;
        uint8[] memory coinFlip = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            coinFlip[i] = uint8(randomWords[i] % 2);

            if (coinFlip[i] == 1 && game.isHeads == true) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
                continue;
            }
            if (coinFlip[i] == 0 && game.isHeads == false) {
                totalValue += int256((game.wager * 9800) / 10000);
                payout += (game.wager * 19800) / 10000;
                payouts[i] = (game.wager * 19800) / 10000;
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
            coinFlip,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (coinIDs[requestId]);
        delete (coinFlipGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    function _checkWager(uint256 wager, address tokenAddress) internal view {
        uint256 maxWager = getMaxWager(tokenAddress);
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
    }

    function getMaxWager(address tokenAddress) public view returns (uint256) {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * 1122448) / 100000000;
        return maxWager;
    }

    function getGameInfos()
        external
        view
        returns (address[] memory, uint256[] memory)
    {
        address[] memory allTokens = Bankroll.viewAllowedTokens();
        address[] memory tokens = new address[](allTokens.length + 1);
        uint256[] memory maxWagers = new uint256[](allTokens.length + 1);
        uint256 i = 0;

        for (i; i < allTokens.length; i++) {
            if (Bankroll.getIsTokenAllowed(allTokens[i])) {
                tokens[i] = allTokens[i];
                maxWagers[i] = getMaxWager(allTokens[i]);
            }
        }
        tokens[i] = address(0);
        maxWagers[i] = getMaxWager(address(0));

        return (tokens, maxWagers);
    }
}
