// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

interface InterfaceValidator {
    enum Status {
        // validator not exist, default status
        NotExist,
        // validator created
        Created,
        // anyone has staked for the validator
        Staked,
        // validator's staked coins < MinimalStakingCoin
        Unstaked,
        // validator is jailed by system (validator have to repropose)
        Jailed
    }
    struct Description {
        string moniker;
        string identity;
        string website;
        string email;
        string details;
    }
    function getTopValidators() external view returns(address[] memory);
    function getValidatorInfo(address val)external view returns(address payable, Status, uint256, uint256, uint256, address[] memory);
    function getValidatorDescription(address val) external view returns ( string memory,string memory,string memory,string memory,string memory);
    function totalStake() external view returns(uint256);
    function getStakingInfo(address staker, address validator) external view returns(uint256, uint256, uint256);
    function viewStakeReward(address _staker, address _validator) external view returns(uint256);
    function MinimalStakingCoin() external view returns(uint256);
    function isTopValidator(address who) external view returns (bool);
    function StakingLockPeriod() external view returns(uint64);
    function UnstakeLockPeriod() external view returns(uint64);


    //write functions
    function createOrEditValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external payable  returns (bool);

    function unstake(address validator)
        external
        returns (bool);

    function withdrawProfits(address validator) external returns (bool);
}


abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }

    function _msgData() internal view virtual returns (bytes calldata) {
        return msg.data;
    }
}

contract ValidatorHelper {

    InterfaceValidator public valContract = InterfaceValidator(0x0000000000000000000000000000000000000001);
    uint256 public minimumValidatorStaking = 1000000 * 1e18;
    uint256 public lastRewardedBlock ;
    uint256 public extraRewardsPerBlock = 1 * 1e18;
    uint256 public rewardFund;
    mapping(address=>uint256) public rewardBalance;
    mapping(address=>uint256) public totalProfitWithdrawn;

    //events
    event Stake(address validator, uint256 amount, uint256 timestamp);
    event Unstake(address validator, uint256 timestamp);
    event WithdrawProfit(address validator, uint256 amount, uint256 timestamp);

    receive() external payable {
        rewardFund += msg.value;
    }


    function createOrEditValidator(
        address payable feeAddr,
        string calldata moniker,
        string calldata identity,
        string calldata website,
        string calldata email,
        string calldata details
    ) external payable  returns (bool) {

        _distributeRewards();

        require(msg.value >= minimumValidatorStaking, "Please stake minimum validator staking" );

        valContract.createOrEditValidator{value: msg.value}(feeAddr, moniker, identity, website, email, details);

        emit Stake(msg.sender, msg.value, block.timestamp);

        return true;
    }


    function unstake(address validator)
        external
        returns (bool)
    {
        _distributeRewards();

        valContract.unstake(validator);

        emit Unstake(msg.sender, block.timestamp);
        return true;
    }

    function withdrawStakingReward(address validator) external {
        require(validator == tx.origin, "caller should be real validator");
        uint256 blockRewards = viewValidatorRewards(validator);
        require(blockRewards > 0, "Nothing to withdraw");

        _distributeRewards();
	valContract.withdrawProfits(validator);

        rewardFund -= blockRewards;

        rewardBalance[validator] = 0;
        totalProfitWithdrawn[validator] += blockRewards;

        payable(validator).transfer(blockRewards);

        emit WithdrawProfit( validator,  blockRewards,  block.timestamp);
    }

    function viewValidatorRewards(address validator) public view returns(uint256 rewardAmount){

        (, InterfaceValidator.Status validatorStatus, , , ,  ) = valContract.getValidatorInfo(validator);


        // if validator is jailed, non-exist, or created, then he will not get any rewards
        if(validatorStatus == InterfaceValidator.Status.Jailed || validatorStatus == InterfaceValidator.Status.NotExist || validatorStatus == InterfaceValidator.Status.Created ){
            return 0;
        }


        // if this smart contract has enough fund and if this validator is not unstaked,
        // then he will receive the block rewards.
        // block reward is dynamically calculated based on total blocks mined
        if(rewardFund >= extraRewardsPerBlock && address(this).balance > extraRewardsPerBlock && validatorStatus != InterfaceValidator.Status.Unstaked){
            address[] memory highestValidatorsSet = valContract.getTopValidators();

            uint256 totalValidators = highestValidatorsSet.length;

            if(block.number - lastRewardedBlock >= totalValidators ){
                rewardAmount = (block.number - lastRewardedBlock) * extraRewardsPerBlock / totalValidators;
            }
        }

        return rewardBalance[validator] + rewardAmount;
    }

    function _distributeRewards() internal {

        address[] memory highestValidatorsSet = valContract.getTopValidators();
        uint256 totalValidators = highestValidatorsSet.length;

        for(uint8 i=0; i < totalValidators; i++){

            rewardBalance[highestValidatorsSet[i]] = viewValidatorRewards(highestValidatorsSet[i]);

        }
        lastRewardedBlock = block.number;

    }
    function getAllValidatorInfo() external view returns (uint256 totalValidatorCount,uint256 totalStakedCoins,address[] memory,InterfaceValidator.Status[] memory,uint256[] memory,string[] memory,string[] memory)
    {
        address[] memory highestValidatorsSet = valContract.getTopValidators();

        uint256 totalValidators = highestValidatorsSet.length;
	uint256 totalunstaked ;
        InterfaceValidator.Status[] memory statusArray = new InterfaceValidator.Status[](totalValidators);
        uint256[] memory coinsArray = new uint256[](totalValidators);
        string[] memory identityArray = new string[](totalValidators);
        string[] memory websiteArray = new string[](totalValidators);

        for(uint8 i=0; i < totalValidators; i++){
            (, InterfaceValidator.Status status, uint256 coins, , , ) = valContract.getValidatorInfo(highestValidatorsSet[i]);
	if(coins>0){
            (, string memory identity, string memory website, ,) = valContract.getValidatorDescription(highestValidatorsSet[i]);

            statusArray[i] = status;
            coinsArray[i] = coins;
            identityArray[i] = identity;
            websiteArray[i] = website;
 	}

        else

        {
            totalunstaked += 1;

	}

        }
        return(totalValidators - totalunstaked , valContract.totalStake(), highestValidatorsSet, statusArray, coinsArray, identityArray, websiteArray);


    }


    function validatorSpecificInfo1(address validatorAddress, address user) external view returns(string memory identityName, string memory website, string memory otherDetails, uint256 withdrawableRewards, uint256 stakedCoins, uint256 waitingBlocksForUnstake ){

        (, string memory identity, string memory websiteLocal, ,string memory details) = valContract.getValidatorDescription(validatorAddress);


        uint256 unstakeBlock;

        (stakedCoins, unstakeBlock, ) = valContract.getStakingInfo(validatorAddress,validatorAddress);

        if(unstakeBlock!=0){
            waitingBlocksForUnstake = stakedCoins;
            stakedCoins = 0;
        }

        return(identity, websiteLocal, details, viewValidatorRewards(validatorAddress), stakedCoins, waitingBlocksForUnstake) ;
    }


    function validatorSpecificInfo2(address validatorAddress, address user) external view returns(uint256 totalStakedCoins, InterfaceValidator.Status status, uint256 selfStakedCoins, uint256 masterVoters, uint256 stakers, address){
        address[] memory stakersArray;
        (, status, totalStakedCoins, , , stakersArray)  = valContract.getValidatorInfo(validatorAddress);

        (selfStakedCoins, , ) = valContract.getStakingInfo(validatorAddress,validatorAddress);

        return (totalStakedCoins, status, selfStakedCoins, 0, stakersArray.length, user);
    }



    function totalProfitEarned(address validator) public view returns(uint256){
        return totalProfitWithdrawn[validator] + viewValidatorRewards(validator);
    }

    function waitingWithdrawProfit(address user, address validatorAddress) external view returns(uint256){
        // no waiting to withdraw profit.
        // this is kept for backward UI compatibility

       return 0;
    }

    function waitingUnstaking(address user, address validator) external view returns(uint256){

        // this function is kept as it is for the UI compatibility
        // no waiting for unstaking
        return 0;
    }

    function waitingWithdrawStaking(address user, address validatorAddress) public view returns(uint256){

        // validator and delegators will have waiting

        (, uint256 unstakeBlock, ) = valContract.getStakingInfo(user,validatorAddress);

        if(unstakeBlock==0){
            return 0;
        }

        if(unstakeBlock + valContract.StakingLockPeriod() > block.number){
            return 2 * ((unstakeBlock + valContract.StakingLockPeriod()) - block.number);
        }

       return 0;

    }

    function minimumStakingAmount() external view returns(uint256){
        return valContract.MinimalStakingCoin();
    }

    function stakingValidations(address user, address validatorAddress) external view returns(uint256 minimumStakingAmt, uint256 stakingWaiting){
        return (valContract.MinimalStakingCoin(), waitingWithdrawStaking(user, validatorAddress));
    }

    function checkValidator(address user) external view returns(bool){
        // this function is for UI compatibility
        return true;
    }
}         
