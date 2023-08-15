// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

import "../Common.sol";

contract Slots is Common {
    using SafeERC20 for IERC20;

    constructor(
        address _chainlinkVRF,
        bytes32 _chainlinkVRFKeyHash,
        uint64 _chainlinkVRFSubscriptionId,
        address _bankroll,
        address link_eth_feed,
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes
    ) {
        Bankroll = IBankRoll(_bankroll);
        IChainLinkVRF = IVRFCoordinatorV2(_chainlinkVRF);
        LINK_ETH_FEED = AggregatorV3Interface(link_eth_feed);
        ChainLinkVRF = _chainlinkVRF;
        chainlinkVRFKeyHash = _chainlinkVRFKeyHash;
        chainlinkVRFSubscriptionId = _chainlinkVRFSubscriptionId;
        _setSlotsMultipliers(_multipliers, _outcomeNum, _numOutcomes);
    }

    struct SlotsGame {
        uint256 wager;
        uint256 stopGain;
        uint256 stopLoss;
        uint256 requestID;
        address tokenAddress;
        uint64 blockNumber;
        uint32 numBets;
    }

    mapping(address => SlotsGame) slotsGames;
    mapping(uint256 => address) slotsIDs;

    mapping(uint16 => uint16) slotsMultipliers;
    uint16 numOutcomes;

    event gamePlayEvent(
        address indexed playerAddress,
        uint256 wager,
        address tokenAddress,
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
        uint16[] slotIDs,
        uint256[] multipliers,
        uint256[] payouts,
        uint32 numGames
    );

    event gameRefundEvent(
        address indexed player,
        uint256 wager,
        address tokenAddress
    );

    error AwaitingVRF(uint256 requestID);
    error InvalidNumBets(uint256 maxNumBets);
    error NotAwaitingVRF();
    error WagerAboveLimit(uint256 wager, uint256 maxWager);
    error BlockNumberTooLow(uint256 have, uint256 want);
    error OnlyCoordinatorCanFulfill(address have, address want);

    function gameGetState(
        address player
    ) external view returns (SlotsGame memory) {
        return (slotsGames[player]);
    }

    function gamePlay(
        uint256 wager,
        address tokenAddress,
        uint32 numBets,
        uint256 stopGain,
        uint256 stopLoss
    ) external payable nonReentrant {
        if (slotsGames[msg.sender].requestID != 0) {
            revert AwaitingVRF(slotsGames[msg.sender].requestID);
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

        slotsGames[msg.sender] = SlotsGame(
            wager,
            stopGain,
            stopLoss,
            id,
            tokenAddress,
            uint64(block.number),
            numBets
        );
        slotsIDs[id] = msg.sender;

        emit gamePlayEvent(
            msg.sender,
            wager,
            tokenAddress,
            numBets,
            stopGain,
            stopLoss,
            fee
        );
    }

    function gameRefund() external nonReentrant {
        require(tx.origin == msg.sender, "no contracts refunds allowed"); // this is intended and will be compensated manually
        SlotsGame storage game = slotsGames[msg.sender];
        if (game.requestID == 0) {
            revert NotAwaitingVRF();
        }
        if (game.blockNumber + 200 > block.number) {
            revert BlockNumberTooLow(block.number, game.blockNumber + 200);
        }

        uint256 wager = game.wager * game.numBets;
        address tokenAddress = game.tokenAddress;

        delete (slotsIDs[game.requestID]);
        delete (slotsGames[msg.sender]);

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
        address playerAddress = slotsIDs[requestId];
        if (playerAddress == address(0)) revert();
        SlotsGame storage game = slotsGames[playerAddress];

        uint256 payout;
        int256 totalValue;
        uint32 i;
        uint16[] memory slotID = new uint16[](game.numBets);
        uint256[] memory multipliers = new uint256[](game.numBets);
        uint256[] memory payouts = new uint256[](game.numBets);

        address tokenAddress = game.tokenAddress;

        for (i = 0; i < game.numBets; i++) {
            if (totalValue >= int256(game.stopGain)) {
                break;
            }
            if (totalValue <= -int256(game.stopLoss)) {
                break;
            }

            slotID[i] = uint16(randomWords[i] % numOutcomes);
            multipliers[i] = slotsMultipliers[slotID[i]];

            if (multipliers[i] != 0) {
                totalValue +=
                    int256(game.wager * multipliers[i]) -
                    int256(game.wager);
                payout += game.wager * multipliers[i];
                payouts[i] = game.wager * multipliers[i];
            } else {
                totalValue -= int256(game.wager);
            }
        }

        payout += (game.numBets - i) * game.wager;

        emit gameOutcomeEvent(
            playerAddress,
            game.wager,
            payout,
            tokenAddress,
            slotID,
            multipliers,
            payouts,
            i
        );

        _transferToBankroll(tokenAddress, game.wager * game.numBets);
        delete (slotsIDs[requestId]);
        delete (slotsGames[playerAddress]);
        if (payout != 0) {
            _transferPayout(playerAddress, payout, tokenAddress);
        }
    }

    function _setSlotsMultipliers(
        uint16[] memory _multipliers,
        uint16[] memory _outcomeNum,
        uint16 _numOutcomes
    ) internal {
        for (uint16 i = 0; i < numOutcomes; i++) {
            delete (slotsMultipliers[i]);
        }

        numOutcomes = _numOutcomes;
        for (uint16 i = 0; i < _multipliers.length; i++) {
            slotsMultipliers[_outcomeNum[i]] = _multipliers[i];
        }
    }

    function Slots_GetMultipliers()
        external
        view
        returns (uint16[] memory multipliers)
    {
        multipliers = new uint16[](numOutcomes);
        for (uint16 i = 0; i < numOutcomes; i++) {
            multipliers[i] = slotsMultipliers[i];
        }
        return multipliers;
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
        uint256 maxWager = (balance * 55770) / 100000000;
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
