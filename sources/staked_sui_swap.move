module staked_sui_swap::staked_sui_swap {
    use sui::package::{Self, Publisher}; 
    use sui::object::{Self, UID}; 
    use sui::dynamic_field::{Self}; 
    use sui::coin::{Self, Coin}; 
    use sui::balance::{Self, Balance}; 
    use sui::tx_context::{Self, TxContext};
    use sui::transfer::{Self};

    use sui_system::staking_pool::{Self, StakedSui};

    struct STAKED_SUI_SWAP has drop {}

    const ERR_NOT_ADMIN: u64 = 0;
    const ERR_NOT_ENOUGH_STAKED_SUI: u64 = 1;
    const ERR_ALREADY_STAKED: u64 = 2;
    const ERR_NOT_STAKED: u64 = 3;
    const ERR_NOT_ENOUGH_TOKEN: u64 = 4;
    const ERR_NOT_ENOUGH_TOKEN_IN_POOL: u64 = 5;

    struct Pool<phantom P> has key, store {
        id: UID,
        k: u256,
        balance_p: Balance<P>,
        balance_staked_sui: u256,
    }

    struct WalletEntryKey has drop, store, copy {
        address: address
    }

    fun init(otw: STAKED_SUI_SWAP, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);
    }

    /*
        The `balance_staked_sui` is a placeholder value only, as the StakedSui is not fungible, 
        it is here to make the AMM equation `k = x * y` work.
    */
    public fun create_pool<P>(publisher: &Publisher, coin_t: Coin<P>, balance_staked_sui: u256, ctx: &mut TxContext) {
        assert!(package::from_module<STAKED_SUI_SWAP>(publisher), ERR_NOT_ADMIN);
        let balance_p = coin::into_balance<P>(coin_t);
        let balance_p_value = (balance::value(&balance_p) as u256);

        let pool = Pool<P> {
            id: object::new(ctx),
            balance_p: balance_p,
            balance_staked_sui: balance_staked_sui,
            k: balance_p_value * balance_staked_sui
        };

        transfer::public_share_object(pool);
    }

    public fun swap_staked_sui<P>(pool: &mut Pool<P>, staked_sui: StakedSui, ctx: &mut TxContext) {
        let df_key = WalletEntryKey { address: tx_context::sender(ctx) };
        assert!(!dynamic_field::exists_(&pool.id, df_key), ERR_ALREADY_STAKED);

        let sui_balance = staking_pool::staked_sui_amount(&staked_sui);
        let p_balance = balance::value(&pool.balance_p);

        let profile_token_out = calculate_p_amount_out(
            (sui_balance as u256), 
            (p_balance as u256),
            pool.balance_staked_sui, 
            pool.k
        );

        assert!(p_balance >= profile_token_out, ERR_NOT_ENOUGH_TOKEN_IN_POOL);

        pool.balance_staked_sui = pool.balance_staked_sui + (sui_balance as u256);
        dynamic_field::add(&mut pool.id, df_key, staked_sui);
        
        let splited_balance = balance::split<P>(&mut pool.balance_p, profile_token_out);
        transfer::public_transfer(coin::from_balance(splited_balance, ctx), tx_context::sender(ctx));
    }

    public fun swap_token<P>(pool: &mut Pool<P>, coin: &mut Coin<P>, ctx: &mut TxContext) {
        let df_key = WalletEntryKey { address: tx_context::sender(ctx) };
        assert!(dynamic_field::exists_(&pool.id, df_key), ERR_NOT_STAKED);
        
        let staked_sui = dynamic_field::remove<WalletEntryKey, StakedSui>(&mut pool.id, df_key);
        let sui_balance = staking_pool::staked_sui_amount(&staked_sui);
        let p_balance = balance::value(&pool.balance_p);
        let profile_token_required = calculate_p_amount_in(
            (sui_balance as u256), 
            (p_balance as u256),
            pool.balance_staked_sui, 
            pool.k
        );

        assert!(coin::value(coin) >= profile_token_required, ERR_NOT_ENOUGH_TOKEN);

        pool.balance_staked_sui = pool.balance_staked_sui - (sui_balance as u256);

        let splited_balance = coin::split<P>(coin, profile_token_required, ctx);
        balance::join(&mut pool.balance_p, coin::into_balance(splited_balance));

        transfer::public_transfer(staked_sui, tx_context::sender(ctx));
    }

    public fun calculate_p_amount_out(delta_sui: u256, p: u256, sui: u256, k: u256): u64 {
        ((p - (k / (sui + delta_sui))) as u64)
    }

    public fun calculate_p_amount_in(delta_sui: u256, p: u256, sui: u256, k: u256): u64 {
        (((k / (sui - delta_sui)) - p) as u64)
    }

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(STAKED_SUI_SWAP{}, ctx);
    }
}

#[test_only]
module staked_sui_swap::staked_sui_swap_test {
    use std::vector::{Self};

    use sui::coin::{Self, Coin};
    use sui::sui::{SUI};
    use sui::test_scenario::{Self, ctx, Scenario};
    use sui::package::{Publisher};

    use sui_system::staking_pool::{StakedSui};
    use sui_system::sui_system::{Self, SuiSystemState};

    use staked_sui_swap::staked_sui_swap::{Self as s, Pool};

    const ADMIN: address = @0x000000;
    const USER_1: address = @0x000001;
    const USER_2: address = @0x000002;
    const VALIDATOR_ADDR: address = @0x000003;
    const MIST_PER_SUI: u64 = 1_000_000_000;

    struct ProfileToken has drop {}

    fun init_pool(scenario: &mut Scenario, profile_token_amount: u64, sui_amount: u64): Pool<ProfileToken> {
        test_scenario::next_tx(scenario, ADMIN);
        {
            s::test_init(ctx(scenario));  
        };

        test_scenario::next_tx(scenario, ADMIN);

        let publisher = test_scenario::take_from_address<Publisher>(scenario, ADMIN);
        let profile_tokens = coin::mint_for_testing<ProfileToken>(profile_token_amount, ctx(scenario));

        {
            s::create_pool(&publisher, profile_tokens,  (sui_amount as u256), ctx(scenario));
        };

        test_scenario::next_tx(scenario, ADMIN);
        test_scenario::return_to_address(ADMIN, publisher);
        test_scenario::take_shared<s::Pool<ProfileToken>>(scenario)
    }

    fun init_validator(scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, VALIDATOR_ADDR);
        {
            let validators = vector[]; 
            let validator = sui_system::governance_test_utils::create_validator_for_testing(VALIDATOR_ADDR, 1_000_000, ctx(scenario));
            vector::push_back(&mut validators, validator);
            sui_system::governance_test_utils::create_sui_system_state_for_testing(validators, 1_000_00, 1_000_000, ctx(scenario));
        };
    }

    fun create_staked_sui(scenario: &mut Scenario, user: address, amount: u64): StakedSui {
        test_scenario::next_tx(scenario, user);
        {
            let system_state = test_scenario::take_shared<SuiSystemState>(scenario);
            let sui_for_staking = coin::mint_for_testing<SUI>(amount, ctx(scenario));
            sui_system::request_add_stake(&mut system_state, sui_for_staking, VALIDATOR_ADDR, ctx(scenario));
            test_scenario::return_shared(system_state);
        };

        test_scenario::next_tx(scenario, user);
        
        test_scenario::take_from_address<StakedSui>(scenario, user)
    }

    fun buy_profile_token(scenario: &mut Scenario, pool: &mut Pool<ProfileToken>, staked_sui: StakedSui, user: address): Coin<ProfileToken> {
        test_scenario::next_tx(scenario, user);
        {
            s::swap_staked_sui(pool, staked_sui, ctx(scenario));
        };
        test_scenario::next_tx(scenario, user);
        test_scenario::take_from_address<Coin<ProfileToken>>(scenario, user)
    }

    fun sell_profile_token(scenario: &mut Scenario, pool: &mut Pool<ProfileToken>, coin: &mut Coin<ProfileToken>, user: address): StakedSui {
        let origin_value = coin::value(coin);
        test_scenario::next_tx(scenario, user);
        {
            s::swap_token(pool, coin, ctx(scenario));
        };
        test_scenario::next_tx(scenario, user);
        let new_value = coin::value(coin);

        assert!(new_value < origin_value, 1);

        test_scenario::take_from_address<StakedSui>(scenario, user)
    }

    #[test]
    public fun test_pool_creation() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        test_scenario::next_tx(scenario, USER_1);

        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_buy_profile_token() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);
       
        let staked_sui = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let profile_token = buy_profile_token(scenario, &mut pool, staked_sui, USER_1);

        assert!(coin::value(&profile_token) > 0, 1);
        test_scenario::return_to_address(USER_1, profile_token);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_buy_and_sell_profile_token() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);
       
        let staked_sui = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let profile_token = buy_profile_token(scenario, &mut pool, staked_sui, USER_1);
        let staked_sui = sell_profile_token(scenario, &mut pool, &mut profile_token, USER_1);

        assert!(coin::value(&profile_token) == 0, 1);
        test_scenario::return_to_address(USER_1, profile_token);
        test_scenario::return_to_address(USER_1, staked_sui);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    public fun test_buy_and_sell_profile_token_with_two_wallet_user_1() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);
       
        let staked_sui_user_1 = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let staked_sui_user_2 = create_staked_sui(scenario, USER_2, 1 * MIST_PER_SUI);
        let profile_token_user_1 = buy_profile_token(scenario, &mut pool, staked_sui_user_1, USER_1);
        let profile_token_user_2 = buy_profile_token(scenario, &mut pool, staked_sui_user_2, USER_2);
        let staked_sui_user_1 = sell_profile_token(scenario, &mut pool, &mut profile_token_user_1, USER_1);

        // USER_1 earns some profit, he gets the StakedSui back and has some ProfileToken left
        assert!(coin::value(&profile_token_user_1) > 0, 1);
        test_scenario::return_to_address(USER_1, profile_token_user_1);
        test_scenario::return_to_address(USER_2, profile_token_user_2);
        test_scenario::return_to_address(USER_1, staked_sui_user_1);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure]
    public fun test_buy_and_sell_profile_token_with_two_wallet_user_2() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);
       
        let staked_sui_user_1 = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let staked_sui_user_2 = create_staked_sui(scenario, USER_2, 1 * MIST_PER_SUI);
        let profile_token_user_1 = buy_profile_token(scenario, &mut pool, staked_sui_user_1, USER_1);
        let profile_token_user_2 = buy_profile_token(scenario, &mut pool, staked_sui_user_2, USER_2);
        let staked_sui_user_1 = sell_profile_token(scenario, &mut pool, &mut profile_token_user_1, USER_1);

        // USER_1 earns some profit, he gets the StakedSui back and has some ProfileToken left
        assert!(coin::value(&profile_token_user_1) > 0, 1);
        test_scenario::return_to_address(USER_1, profile_token_user_1);

        // This will fail, because USER_2 do not have enough ProfileToken to buy back his StakedSui
        let staked_sui_user_2 = sell_profile_token(scenario, &mut pool, &mut profile_token_user_2, USER_2);

        test_scenario::return_to_address(USER_2, profile_token_user_2);
        test_scenario::return_to_address(USER_1, staked_sui_user_1);
        test_scenario::return_to_address(USER_2, staked_sui_user_2);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure]
    public fun test_buy_twice() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);

        let staked_sui_user_1_1 = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let staked_sui_user_1_2 = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let profile_token_user_1_1 = buy_profile_token(scenario, &mut pool, staked_sui_user_1_1, USER_1);
        let profile_token_user_1_2 = buy_profile_token(scenario, &mut pool, staked_sui_user_1_2, USER_1);

        test_scenario::return_to_address(USER_1, profile_token_user_1_1);
        test_scenario::return_to_address(USER_1, profile_token_user_1_2);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }

    #[test]
    #[expected_failure]
    public fun test_sell_with_different_wallet() {
        let scenario_val = test_scenario::begin(ADMIN);
        let scenario = &mut scenario_val;

        let pool = init_pool(scenario, 1_000 * MIST_PER_SUI, 1_000 * MIST_PER_SUI);

        init_validator(scenario);

        let staked_sui_user_1 = create_staked_sui(scenario, USER_1, 1 * MIST_PER_SUI);
        let profile_token_user_1 = buy_profile_token(scenario, &mut pool, staked_sui_user_1, USER_1);
        let staked_sui_user_2 = sell_profile_token(scenario, &mut pool, &mut profile_token_user_1, USER_2);

        test_scenario::return_to_address(USER_1, profile_token_user_1);
        test_scenario::return_to_address(USER_2, staked_sui_user_2);
        test_scenario::return_shared(pool);
        test_scenario::end(scenario_val);
    }
}
