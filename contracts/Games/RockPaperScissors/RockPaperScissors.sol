// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../Common.sol";

contract RockPaperScissors is Common {
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

    struct RockPaperScissorsGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
        uint8 action;
    }

    mapping(address => RockPaperScissorsGame) rockPaperScissorsGames;
    mapping(uint256 => address) rockPaperScissorsIDs;

    event gamePlayEvent(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
        uint8 action,
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
        uint8[] outcomes,
        uint8[] randomActions,
        uint256[] payouts,
        uint32 numGames
    );

    event gameRefundEvent(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidAction();
    error InvalidNumBets(uint256 maxNumBets);
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error NotAwaitingVRF();
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    function gameGetState(
        address player
    ) external view returns (RockPaperScissorsGame memory) {
        return (rockPaperScissorsGames[player]);
    }

    function gamePlay(
        uint256 wager,
        address tokenAddress,
        uint8 action,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        if (action >= 3) {
            revert InvalidAction();
        }
        if (rockPaperScissorsGames[msg.sender].requestID != 0) {
            revert AwaitingVRF(rockPaperScissorsGames[msg.sender].requestID);
        }
        if (!(numBets > 0 && numBets <= 100)) {
            revert InvalidNumBets(100);
        }

        _checkWager(wager, tokenAddress);
        uint256 fee = _transferWager(
            tokenAddress,
            wager * numBets,
            1100000,
            msg.sender
        );
        uint256 id = _requestRandomWords(numBets);

        rockPaperScissorsGames[msg.sender] = RockPaperScissorsGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets,
            action
        );
        rockPaperScissorsIDs[id] = msg.sender;

        emit gamePlayEvent(
            msg.sender,
            wager,
            tokenAddress,
            action,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    function gameRefund() external nonReentrant {
        RockPaperScissorsGame storage game = rockPaperScissorsGames[msg.sender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > block.number) {
            revert BlockNumberTooLow(block.number, game.blockNumber + 200);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (rockPaperScissorsIDs[game.requestID]);
        delete (rockPaperScissorsGames[msg.sender]);

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
        address playerAddress = rockPaperScissorsIDs[requestId];
        if (playerAddress == address(0)) revert();
        RockPaperScissorsGame storage game = rockPaperScissorsGames[
            playerAddress
        ];

        uint8[] memory randomActions = new uint8[](game.numBets);
        uint8[] memory outcomes = new uint8[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);
        int256 totalValue;
        uint256 payout;
        uint32 i;

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            randomActions[i] = uint8(randomWords[i] % 3);
            outcomes[i] = _determineRPSResult(game.action, randomActions[i]);

            if (outcomes[i] == 2) {
                payout += (game.wager * 99) / 100;
                totalValue -= int256((game.wager) / 100);
                payouts[i] = (game.wager * 99) / 100;
                continue;
            }

            if (outcomes[i] == 1) {
                payout += (game.wager * 198) / 100;
                totalValue += int256((game.wager * 98) / 100);
                payouts[i] = (game.wager * 198) / 100;
                continue;
            }

            totalValue -= int256(game.wager);
        }

        payout += (game.numBets - i) * game.wager;

        emit gameOutcomeEvent(
            playerAddress,
            game.wager,
            payout,
            game.tokenAddress,
            outcomes,
            randomActions,
            payouts,
            i
        );
        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (rockPaperScissorsIDs[requestId]);
        delete (rockPaperScissorsGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    // 0 loss, 1-> win, 2-> draw //0->Rock, 1-> Paper, 2->Scissors
    function _determineRPSResult(
        uint8 playerPick,
        uint8 rngPick
    ) internal pure returns (uint8) {
        if (playerPick == rngPick) {
            return 2;
        }
        if (playerPick == 0) {
            if (rngPick == 1) {
                return 0;
            } else {
                return 1;
            }
        }

        if (playerPick == 1) {
            if (rngPick == 2) {
                return 0;
            } else {
                return 1;
            }
        }

        if (playerPick == 2) {
            if (rngPick == 0) {
                return 0;
            } else {
                return 1;
            }
        }
        return 2;
    }

    function getMaxWager(address tokenAddress) public view returns (uint256) {
        uint256 balance;
        if (tokenAddress == address(0)) {
            balance = address(Bankroll).balance;
        } else {
            balance = IERC20(tokenAddress).balanceOf(address(Bankroll));
        }
        uint256 maxWager = (balance * 1683629) / 100000000;
        return maxWager;
    }

    function _checkWager(uint256 wager, address tokenAddress) internal view {
        uint256 maxWager = getMaxWager(tokenAddress);
        if (wager > maxWager) {
            revert WagerAboveLimit(wager, maxWager);
        }
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
