// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import "./Params.sol";
import "./Punish.sol";

abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

contract Validators is Params {
    constructor(address[] memory vals) {
        punish = Punish(PunishContractAddr);

        for (uint256 i = 0; i < vals.length; i++) {
            require(vals[i] != address(0), "Invalid validator address");
            lastRewardTime[vals[i]] = block.timestamp;

            if (!isActiveValidator(vals[i])) {
                currentValidatorSet.push(vals[i]);
            }
            if (!isTopValidator(vals[i])) {
                highestValidatorsSet.push(vals[i]);
            }
            if (validatorInfo[vals[i]].feeAddr == address(0)) {
                validatorInfo[vals[i]].feeAddr = payable(vals[i]);
            }
            // Important: NotExist validator can't get profits
            if (validatorInfo[vals[i]].status == Status.NotExist) {
                validatorInfo[vals[i]].status = Status.Staked;
            }
        }
        initialized = true;
    }
    enum Status {
        NotExist,
        Created,
        Staked,
        Unstaked,
        Jailed
    }

    struct Description {
        string moniker;
        string identity;
        string website;
        string email;
        string details;
    }

    struct Validator {
        address payable feeAddr;
        Status status;
        uint256 coins;
        Description description;
        uint256 hbIncoming;
        uint256 totalJailedHB;
        address[] stakers;
    }

    struct StakingInfo {
        uint256 coins;
        uint256 unstakeBlock;
        uint256 index;
    }

    mapping(address => Validator) validatorInfo;
    mapping(address => mapping(address => StakingInfo)) staked;
    address[] public currentValidatorSet;
    address[] public highestValidatorsSet;
    uint256 public totalStake;
    uint256 public totalJailedHB;
    mapping(address => address) public contractCreator;
    mapping(address => mapping(address => uint)) public stakeTime;
    mapping( address => uint) public lastRewardTime;
    mapping(address => mapping( uint => uint )) public reflectionPercentSum;
    Punish punish;
    enum Operations {Distribute, UpdateValidators}
    mapping(uint256 => mapping(uint8 => bool)) operationsDone;

    event LogCreateValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogEditValidator(
        address indexed val,
        address indexed fee,
        uint256 time
    );
    event LogReactive(address indexed val, uint256 time);
    event LogAddToTopValidators(address indexed val, uint256 time);
    event LogRemoveFromTopValidators(address indexed val, uint256 time);
    event LogUnstake(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );
    event LogWithdrawStaking(
        address indexed staker,
        address indexed val,
        uint256 amount,
        uint256 time
    );
    event LogWithdrawProfits(
        address indexed val,
        address indexed fee,
        uint256 hb,
        uint256 time
    );
    event LogRemoveValidator(address indexed val, uint256 hb, uint256 time);
    event LogRemoveValidatorIncoming(
        address indexed val,
        uint256 hb,
        uint256 time
    );
    event LogDistributeBlockReward(
        address indexed coinbase,
        uint256 blockReward,
        uint256 time,
        address[] To,
        uint64[] Gass
    );
    event LogUpdateValidator(address[] newSet);
    event LogStake(
        address indexed staker,
        address indexed val,
        uint256 staking,
        uint256 time
    );

    event withdrawStakingRewardEv(address user,address validator,uint reward,uint timeStamp);

    modifier onlyNotRewarded() {
        require(
            operationsDone[block.number][uint8(Operations.Distribute)] == false,
            "Block is already rewarded"
        );
        _;
    }

    modifier onlyNotUpdated() {
        require(
            operationsDone[block.number][uint8(Operations.UpdateValidators)] ==
                false,
            "Validators already updated"
        );
        _;
    }

    function setContractCreator(address _contract ) public returns(bool)
    {
        require(contractCreator[_contract] == address(0), "invalid call");
        contractCreator[_contract] = tx.origin;
        return true;
    }

    function stake(address validator)
        public
        payable
        onlyInitialized
        returns (bool)
    {
        address payable staker = payable(tx.origin);
        uint256 staking = msg.value;

        require(
            validatorInfo[validator].status == Status.Created ||
                validatorInfo[validator].status == Status.Staked,
            "Can't stake to a validator in abnormal status"
        );

        require(
            staked[staker][validator].unstakeBlock == 0,
            "Can't stake when you are unstaking"
        );

        Validator storage valInfo = validatorInfo[validator];
        if(staker == validator){
            require(
                valInfo.coins + (staking) >= MinimalStakingCoin,
                "Staking coins not enough"
            );
        }
        else
        {
            require(staking >= MinimalStakingCoin,
            "Staking coins not enough");
        }
        if (staked[staker][validator].coins == 0) {
            staked[staker][validator].index = valInfo.stakers.length;
            valInfo.stakers.push(staker);
            if(lastRewardTime[validator] == 0)
            {
                lastRewardTime[validator] = block.timestamp;
            }
            stakeTime[staker][validator] = lastRewardTime[validator];
        }
        else
        {
            withdrawStakingReward(validator);
        }

        valInfo.coins = valInfo.coins + (staking);
        if (valInfo.status != Status.Staked) {
            valInfo.status = Status.Staked;
        }
        tryAddValidatorToHighestSet(validator, valInfo.coins);

        // record staker's info
        staked[staker][validator].coins = staked[staker][validator].coins + (
            staking
        );
        totalStake = totalStake + (staking);

        emit LogStake(staker, validator, staking, block.timestamp);
        return true;
    }

    function createOrEditValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external payable onlyInitialized returns (bool) {
        require(feeAddr != address(0), "Invalid fee address");
        require(
            validateDescription(moniker, identity, website, email, details),
            "Invalid description"
        );
        address payable validator = payable(tx.origin);
        bool isCreate = false;
        if (validatorInfo[validator].status == Status.NotExist) {
            validatorInfo[validator].status = Status.Created;
            isCreate = true;
        }
        else  if(msg.value > 0)
        {
             return false;
        }

        if (validatorInfo[validator].feeAddr != feeAddr) {
            validatorInfo[validator].feeAddr = feeAddr;
        }

        validatorInfo[validator].description = Description(
            moniker,
            identity,
            website,
            email,
            details
        );

        if (isCreate) {
            require(msg.value >= minimumValidatorStaking, "Invalid validator amount");
            stake(validator);
            emit LogCreateValidator(validator, feeAddr, block.timestamp);
        } else {
            emit LogEditValidator(validator, feeAddr, block.timestamp);
        }
        return true;
    }

    function tryReactive(address validator)
        external
        onlyInitialized
        returns (bool)
    {
        if (
            validatorInfo[validator].status != Status.Unstaked &&
            validatorInfo[validator].status != Status.Jailed
        ) {
            return true;
        }

        if (validatorInfo[validator].status == Status.Jailed) {
            require(punish.cleanPunishRecord(validator), "clean failed");
        }
        validatorInfo[validator].status = Status.Staked;

        emit LogReactive(validator, block.timestamp);

        return true;
    }

    function unstake(address validator)
        external
        onlyInitialized
        returns (bool)
    {
        address staker = tx.origin;
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );

        StakingInfo storage stakingInfo = staked[staker][validator];
        Validator storage valInfo = validatorInfo[validator];
        uint256 unstakeAmount = stakingInfo.coins;

        require(
            stakingInfo.unstakeBlock == 0,
            "You are already in unstaking status"
        );
        require(unstakeAmount > 0, "You don't have any stake");
        require(
            !(highestValidatorsSet.length == 1 &&
                isTopValidator(validator) &&
                (valInfo.coins - unstakeAmount) < MinimalStakingCoin),
            "You can't unstake, validator list will be empty after this operation!"
        );

        if (stakingInfo.index != valInfo.stakers.length - 1) {
            valInfo.stakers[stakingInfo.index] = valInfo.stakers[valInfo
                .stakers
                .length - 1];
            staked[valInfo.stakers[stakingInfo.index]][validator]
                .index = stakingInfo.index;
        }
        valInfo.stakers.pop();

        valInfo.coins = valInfo.coins - (unstakeAmount);
        stakingInfo.unstakeBlock = block.number;
        stakingInfo.index = 0;
        totalStake = totalStake - (unstakeAmount);
        if (valInfo.coins < MinimalStakingCoin && validatorInfo[validator].status != Status.Jailed) {
            valInfo.status = Status.Unstaked;
            tryRemoveValidatorInHighestSet(validator);
        }

        withdrawStakingReward(validator);
        stakeTime[staker][validator] = 0 ;
        emit LogUnstake(staker, validator, unstakeAmount, block.timestamp);
        return true;
    }

    function withdrawStakingReward(address validator) public returns(bool)
    {
        require(stakeTime[tx.origin][validator] > 0 , "nothing staked");
        StakingInfo storage stakingInfo = staked[tx.origin][validator];
        uint validPercent = reflectionPercentSum[validator][lastRewardTime[validator]] - reflectionPercentSum[validator][stakeTime[tx.origin][validator]];
        if(validPercent > 0)
        {
            stakeTime[tx.origin][validator] = lastRewardTime[validator];
            uint reward = stakingInfo.coins * validPercent / 100000000000000000000  ;
            payable(tx.origin).transfer(reward);
            emit withdrawStakingRewardEv(tx.origin, validator, reward, block.timestamp);
        }
        return true;
    }

    function withdrawStaking(address validator) external returns (bool) {
        address payable staker = payable(tx.origin);
        StakingInfo storage stakingInfo = staked[staker][validator];
        require(
            validatorInfo[validator].status != Status.NotExist,
            "validator not exist"
        );
        require(stakingInfo.unstakeBlock != 0, "You have to unstake first");
        require(
            stakingInfo.unstakeBlock + StakingLockPeriod <= block.number,
            "Your staking haven't unlocked yet"
        );
        uint256 staking = stakingInfo.coins;
        require(staking > 0, "You don't have any stake");
        stakingInfo.coins = 0;
        stakingInfo.unstakeBlock = 0;
        staker.transfer(staking);
        emit LogWithdrawStaking(staker, validator, staking, block.timestamp);
        return true;
    }

    function withdrawProfits(address validator) external returns (bool) {
        address payable feeAddr = payable(tx.origin);
        require(
            validatorInfo[validator].status != Status.NotExist,
            "Validator not exist"
        );
        require(
            validatorInfo[validator].feeAddr == feeAddr,
            "You are not the fee receiver of this validator"
        );
        uint256 hbIncoming = validatorInfo[validator].hbIncoming;
        require(hbIncoming > 0, "You don't have any profits");

        validatorInfo[validator].hbIncoming = 0;

        if (hbIncoming > 0) {
            feeAddr.transfer(hbIncoming);
        }
        withdrawStakingReward(validator);
        emit LogWithdrawProfits(
            validator,
            feeAddr,
            hbIncoming,
            block.timestamp
        );

        return true;
    }


    function distributeBlockReward(address[] memory _to, uint64[] memory _gass)
        external
        payable
        onlyMiner
        onlyNotRewarded
        onlyInitialized
    {
        operationsDone[block.number][uint8(Operations.Distribute)] = true;
        address val = tx.origin;
        uint256 reward = msg.value;
        uint256 remaining = reward;

        // to validator
        uint _validatorPart = reward * 100000;
        remaining = remaining - _validatorPart;

        uint lastRewardHold = reflectionPercentSum[val][lastRewardTime[val]];
        lastRewardTime[val] = block.timestamp;
        if(validatorInfo[val].coins > 0)
        {
            reflectionPercentSum[val][lastRewardTime[val]] = lastRewardHold + (remaining * 100000000000000000000 / validatorInfo[val].coins);
        }
        else
        {
            reflectionPercentSum[val][lastRewardTime[val]] = lastRewardHold;
            _validatorPart += remaining;
        }

        if (validatorInfo[val].status != Status.NotExist) {
            addProfitsToActiveValidatorsByStakePercentExcept(_validatorPart, address(0));
            emit LogDistributeBlockReward(val, _validatorPart, block.timestamp, _to, _gass);
        }
    }


    function updateActiveValidatorSet(address[] memory newSet, uint256 epoch)
        public
        onlyMiner
        onlyNotUpdated
        onlyInitialized
        onlyBlockEpoch(epoch)
    {
        operationsDone[block.number][uint8(Operations.UpdateValidators)] = true;
        require(newSet.length > 0, "Validator set empty!");

        currentValidatorSet = newSet;

        emit LogUpdateValidator(newSet);
    }

    function removeValidator(address val) external onlyPunishContract {
        uint256 hb = validatorInfo[val].hbIncoming;

        tryRemoveValidatorIncoming(val);

        if (highestValidatorsSet.length > 1) {
            tryJailValidator(val);
            emit LogRemoveValidator(val, hb, block.timestamp);
        }
    }

    function removeValidatorIncoming(address val) external onlyPunishContract {
        tryRemoveValidatorIncoming(val);
    }

    function getValidatorDescription(address val)
        public
        view
        returns (
            string memory,
            string memory,
            string memory,
            string memory,
            string memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (
            v.description.moniker,
            v.description.identity,
            v.description.website,
            v.description.email,
            v.description.details
        );
    }

    function getValidatorInfo(address val)
        public
        view
        returns (
            address payable,
            Status,
            uint256,
            uint256,
            uint256,
            //uint256,
            address[] memory
        )
    {
        Validator memory v = validatorInfo[val];

        return (
            v.feeAddr,
            v.status,
            v.coins,
            v.hbIncoming,
            v.totalJailedHB,
            v.stakers
        );
    }

    function getStakingInfo(address staker, address val)
        public
        view
        returns (
            uint256,
            uint256,
            uint256
        )
    {
        return (
            staked[staker][val].coins,
            staked[staker][val].unstakeBlock,
            staked[staker][val].index
        );
    }

    function getActiveValidators() public view returns (address[] memory) {
        return currentValidatorSet;
    }

    function getTotalStakeOfActiveValidators()
        public
        view
        returns (uint256 total, uint256 len)
    {
        return getTotalStakeOfActiveValidatorsExcept(address(0));
    }

    function getTotalStakeOfActiveValidatorsExcept(address val)
        private
        view
        returns (uint256 total, uint256 len)
    {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (
                validatorInfo[currentValidatorSet[i]].status != Status.Jailed &&
                val != currentValidatorSet[i]
            ) {
                total = total + (validatorInfo[currentValidatorSet[i]].coins);
                len++;
            }
        }

        return (total, len);
    }

    function isActiveValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            if (currentValidatorSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function isTopValidator(address who) public view returns (bool) {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == who) {
                return true;
            }
        }

        return false;
    }

    function getTopValidators() public view returns (address[] memory) {
        return highestValidatorsSet;
    }

    function validateDescription(
        string memory moniker,
        string memory identity,
        string memory website,
        string memory email,
        string memory details
    ) public pure returns (bool) {
        require(bytes(moniker).length <= 70, "Invalid moniker length");
        require(bytes(identity).length <= 3000, "Invalid identity length");
        require(bytes(website).length <= 140, "Invalid website length");
        require(bytes(email).length <= 140, "Invalid email length");
        require(bytes(details).length <= 280, "Invalid details length");

        return true;
    }

    function tryAddValidatorToHighestSet(address val, uint256 staking)
        internal
    {
        for (uint256 i = 0; i < highestValidatorsSet.length; i++) {
            if (highestValidatorsSet[i] == val) {
                return;
            }
        }

        if (highestValidatorsSet.length < MaxValidators) {
            highestValidatorsSet.push(val);
            emit LogAddToTopValidators(val, block.timestamp);
            return;
        }

        uint256 lowest = validatorInfo[highestValidatorsSet[0]].coins;
        uint256 lowestIndex = 0;
        for (uint256 i = 1; i < highestValidatorsSet.length; i++) {
            if (validatorInfo[highestValidatorsSet[i]].coins < lowest) {
                lowest = validatorInfo[highestValidatorsSet[i]].coins;
                lowestIndex = i;
            }
        }

        if (staking <= lowest) {
            return;
        }

        emit LogAddToTopValidators(val, block.timestamp);
        emit LogRemoveFromTopValidators(
            highestValidatorsSet[lowestIndex],
            block.timestamp
        );
        highestValidatorsSet[lowestIndex] = val;
    }

    function tryRemoveValidatorIncoming(address val) private {
        if (
            validatorInfo[val].status == Status.NotExist ||
            currentValidatorSet.length <= 1
        ) {
            return;
        }

        uint256 hb = validatorInfo[val].hbIncoming;
        if (hb > 0) {
            addProfitsToActiveValidatorsByStakePercentExcept(hb, val);
            totalJailedHB = totalJailedHB + (hb);
            validatorInfo[val].totalJailedHB = validatorInfo[val]
                .totalJailedHB
                + (hb);

            validatorInfo[val].hbIncoming = 0;
        }

        emit LogRemoveValidatorIncoming(val, hb, block.timestamp);
    }

    function addProfitsToActiveValidatorsByStakePercentExcept(
        uint256 totalReward,
        address punishedVal
    ) private {
        if (totalReward == 0) {
            return;
        }

        uint256 totalRewardStake;
        uint256 rewardValsLen;
        (
            totalRewardStake,
            rewardValsLen
        ) = getTotalStakeOfActiveValidatorsExcept(punishedVal);

        if (rewardValsLen == 0) {
            return;
        }

        uint256 remain;
        address last;

        if (totalRewardStake == 0) {
            uint256 per = totalReward / (rewardValsLen);
            remain = totalReward - (per * rewardValsLen);
            for (uint256 i = 0; i < currentValidatorSet.length; i++) {
                address val = currentValidatorSet[i];
                if (
                    validatorInfo[val].status != Status.Jailed &&
                    val != punishedVal
                ) {
                    validatorInfo[val].hbIncoming = validatorInfo[val]
                        .hbIncoming
                        + (per);

                    last = val;
                }
            }

            if (remain > 0 && last != address(0)) {
                validatorInfo[last].hbIncoming = validatorInfo[last]
                    .hbIncoming
                    + (remain);
            }
            return;
        }

        uint256 added;
        for (uint256 i = 0; i < currentValidatorSet.length; i++) {
            address val = currentValidatorSet[i];
            if (
                validatorInfo[val].status != Status.Jailed && val != punishedVal
            ) {
                uint256 reward = totalReward * (validatorInfo[val].coins) / (
                    totalRewardStake
                );
                added = added + (reward);
                last = val;
                validatorInfo[val].hbIncoming = validatorInfo[val]
                    .hbIncoming
                    + (reward);
            }
        }

        remain = totalReward - (added);
        if (remain > 0 && last != address(0)) {
            validatorInfo[last].hbIncoming = validatorInfo[last].hbIncoming + (
                remain
            );
        }
    }

    function tryJailValidator(address val) private {
        if (validatorInfo[val].status == Status.NotExist) {
            return;
        }

        validatorInfo[val].status = Status.Jailed;

        tryRemoveValidatorInHighestSet(val);
    }

    function tryRemoveValidatorInHighestSet(address val) private {
        for (
            uint256 i = 0;
            i < highestValidatorsSet.length && highestValidatorsSet.length > 1;
            i++
        ) {
            if (val == highestValidatorsSet[i]) {
                if (i != highestValidatorsSet.length - 1) {
                    highestValidatorsSet[i] = highestValidatorsSet[highestValidatorsSet
                        .length - 1];
                }

                highestValidatorsSet.pop();
                emit LogRemoveFromTopValidators(val, block.timestamp);

                break;
            }
        }
    }

    function viewStakeReward(address _staker, address _validator) public view returns(uint256){
        if(stakeTime[_staker][_validator] > 0){
            uint validPercent = reflectionPercentSum[_validator][lastRewardTime[_validator]] - reflectionPercentSum[_validator][stakeTime[_staker][_validator]];
            if(validPercent > 0)
            {
                StakingInfo memory stakingInfo = staked[_staker][_validator];
                return stakingInfo.coins * validPercent / 100000000000000000000  ;
            }
        }
        return 0;
    }

}
