use starknet::ContractAddress;
use cairo_lib::data_structures::mmr::peaks::Peaks;
use cairo_lib::data_structures::mmr::proof::Proof;
use cairo_lib::utils::types::words64::Words64;
use cairo_lib::data_structures::mmr::mmr::MMR;

#[starknet::interface]
trait IHeadersStore<TContractState> {
    fn get_commitments_inbox(self: @TContractState) -> ContractAddress;
    fn get_mmr(self: @TContractState, mmr_id: usize) -> MMR;
    fn get_mmr_root(self: @TContractState, mmr_id: usize) -> felt252;
    fn get_mmr_size(self: @TContractState, mmr_id: usize) -> usize;
    fn get_received_block(self: @TContractState, block_number: u256) -> u256;
    fn get_latest_mmr_id(self: @TContractState) -> usize;
    fn get_historical_root(self: @TContractState, mmr_id: usize, size: usize) -> felt252;

    fn receive_hash(ref self: TContractState, blockhash: u256, block_number: u256);
    fn process_received_block(
        ref self: TContractState,
        block_number: u256, 
        header_rlp: Words64,
        mmr_peaks: Peaks,
        mmr_id: usize,
    );
    fn process_batch(
        ref self: TContractState,
        initial_block: u256, 
        headers_rlp: Span<Words64>,
        mmr_peaks: Peaks,
        mmr_id: usize,
    );

    fn verify_mmr_inclusion(
        self: @TContractState,
        index: usize,
        blockhash: felt252,
        peaks: Peaks,
        proof: Proof,
        mmr_id: usize,
    ) -> bool;
    fn verify_historical_mmr_inclusion(
        self: @TContractState,
        index: usize,
        blockhash: felt252,
        peaks: Peaks,
        proof: Proof,
        mmr_id: usize,
        last_pos: usize,
    ) -> bool;

    fn create_branch_from_message(ref self: TContractState, root: felt252, last_pos: usize);
    fn create_branch_single_element(
        ref self: TContractState, 
        index: usize, 
        blockhash: felt252,
        peaks: Peaks,
        proof: Proof,
        mmr_id: usize,
    );
    fn create_branch_from(ref self: TContractState, mmr_id: usize);
}

#[starknet::contract]
mod HeadersStore {
    use starknet::{ContractAddress, get_caller_address};
    use cairo_lib::data_structures::mmr::mmr::{MMR, MMRTrait};
    use cairo_lib::data_structures::mmr::peaks::Peaks;
    use cairo_lib::data_structures::mmr::proof::Proof;
    use cairo_lib::utils::types::words64::{Words64, Words64TryIntoU256LE};
    use cairo_lib::hashing::keccak::KeccakTrait;
    use cairo_lib::hashing::poseidon::PoseidonHasher;
    use cairo_lib::encoding::rlp_word64::{RLPItemWord64, rlp_decode_word64};
    use zeroable::Zeroable;
    use array::{ArrayTrait, SpanTrait};
    use traits::{Into, TryInto};
    use result::ResultTrait;
    use option::OptionTrait;
    use clone::Clone;
    use debug::PrintTrait;

    const MMR_INITIAL_ROOT: felt252 = 0x6759138078831011e3bc0b4a135af21c008dda64586363531697207fb5a2bae;

    #[storage]
    struct Storage {
        commitments_inbox: ContractAddress,
        mmr: LegacyMap::<usize, MMR>,
        // (id, size) => root
        mmr_history: LegacyMap::<(usize, usize), felt252>,
        received_blocks: LegacyMap::<u256, u256>,
        latest_mmr_id: usize
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        HashReceived: HashReceived,
        ProcessedBlock: ProcessedBlock,
        ProcessedBatch: ProcessedBatch,
        BranchCreated: BranchCreated
    }

    #[derive(Drop, starknet::Event)]
    struct HashReceived {
        block_number: u256,
        blockhash: u256
    }

    #[derive(Drop, starknet::Event)]
    struct ProcessedBlock {
        block_number: u256,
        blockhash: u256,
        blockhash_poseidon: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct ProcessedBatch {
        block_start: u256,
        block_end: u256,
        new_root: felt252,
        new_size: usize
    }

    #[derive(Drop, starknet::Event)]
    struct BranchCreated {
        mmr_id: usize,
        root: felt252,
        last_pos: usize
    }

    #[constructor]
    fn constructor(ref self: ContractState, commitments_inbox: ContractAddress) {
        self.commitments_inbox.write(commitments_inbox);

        let mmr: MMR = MMRTrait::new(MMR_INITIAL_ROOT, 1);
        let root = mmr.root;

        self.mmr.write(0, mmr);
        self.mmr_history.write((0, 1), root);
        self.latest_mmr_id.write(0);
    }

    #[external(v0)]
    impl HeadersStore of super::IHeadersStore<ContractState> {
        fn get_commitments_inbox(self: @ContractState) -> ContractAddress {
            self.commitments_inbox.read()
        }

        fn get_mmr(self: @ContractState, mmr_id: usize) -> MMR {
            self.mmr.read(mmr_id)
        }

        fn get_mmr_root(self: @ContractState, mmr_id: usize) -> felt252 {
            self.mmr.read(mmr_id).root
        }

        fn get_mmr_size(self: @ContractState, mmr_id: usize) -> usize {
            self.mmr.read(mmr_id).last_pos
        }

        fn get_received_block(self: @ContractState, block_number: u256) -> u256 {
            self.received_blocks.read(block_number)
        }

        fn get_latest_mmr_id(self: @ContractState) -> usize {
            self.latest_mmr_id.read()
        }

        fn get_historical_root(self: @ContractState, mmr_id: usize, size: usize) -> felt252 {
            self.mmr_history.read((mmr_id, size))
        }

        fn receive_hash(ref self: ContractState, blockhash: u256, block_number: u256) {
            let caller = get_caller_address();
            assert(caller == self.commitments_inbox.read(), 'Only CommitmentsInbox');

            self.received_blocks.write(block_number, blockhash);

            self.emit(Event::HashReceived(HashReceived {
                block_number,
                blockhash
            }));
        }

        fn process_received_block(
            ref self: ContractState,
            block_number: u256, 
            header_rlp: Words64,
            mmr_peaks: Peaks,
            mmr_id: usize,
        ) {
            let blockhash = self.received_blocks.read(block_number);
            assert(blockhash != Zeroable::zero(), 'Block not received');

            let rlp_hash = KeccakTrait::keccak_cairo_word64(header_rlp);
            assert(rlp_hash == blockhash, 'Invalid header rlp');

            let poseidon_hash = InternalFunctions::poseidon_hash_rlp(header_rlp);

            let mut mmr = self.mmr.read(mmr_id);
            mmr.append(poseidon_hash, mmr_peaks).unwrap();
            self.mmr.write(mmr_id, mmr.clone());

            self.mmr_history.write((mmr_id, mmr.last_pos), mmr.root);

            self.emit(Event::ProcessedBlock(ProcessedBlock {
                block_number,
                blockhash,
                blockhash_poseidon: poseidon_hash
            }));
        }

        fn process_batch(
            ref self: ContractState,
            initial_block: u256, 
            headers_rlp: Span<Words64>,
            mmr_peaks: Peaks,
            mmr_id: usize,
        ) {
            let initial_blockhash = self.received_blocks.read(initial_block);
            assert(initial_blockhash != Zeroable::zero(), 'Block not received');
            // TODO initial block can also be present in the MMR, if present, don't append

            let rlp_hash = KeccakTrait::keccak_cairo_word64(*headers_rlp.at(0));
            assert(rlp_hash == initial_blockhash, 'Invalid initial header rlp');

            let poseidon_hash = InternalFunctions::poseidon_hash_rlp(*headers_rlp.at(0));

            let mut mmr = self.mmr.read(mmr_id);
            mmr.append(poseidon_hash, mmr_peaks).unwrap();

            let mut i: usize = 1;
            loop {
                if i == headers_rlp.len() {
                    break ();
                }

                let child_rlp = *headers_rlp.at(i - 1);
                // TODO error handling
                let (decoded_rlp, _) = rlp_decode_word64(child_rlp).unwrap();
                let parent_hash: u256 = match decoded_rlp {
                    RLPItemWord64::Bytes(_) => panic_with_felt252('Invalid header rlp'),
                    RLPItemWord64::List(l) => {
                        let words = *l.at(0);
                        assert(words.len() == 4, 'Invalid parent_hash rlp');
                        words.try_into().unwrap()
                    },
                };

                let current_rlp = *headers_rlp.at(i);
                let current_hash = KeccakTrait::keccak_cairo_word64(current_rlp);
                assert(current_hash == parent_hash, 'Invalid header rlp');

                let poseidon_hash = InternalFunctions::poseidon_hash_rlp(current_rlp);

                mmr.append(poseidon_hash, mmr_peaks).unwrap();

                i += 1;
            };

            self.mmr.write(mmr_id, mmr.clone());
            self.mmr_history.write((mmr_id, mmr.last_pos), mmr.root);

            self.emit(Event::ProcessedBatch(ProcessedBatch {
                block_start: initial_block,
                block_end: initial_block - headers_rlp.len().into() + 1,
                new_root: mmr.root,
                new_size: mmr.last_pos
            }));
        }

        fn verify_mmr_inclusion(
            self: @ContractState,
            index: usize,
            blockhash: felt252,
            peaks: Peaks,
            proof: Proof,
            mmr_id: usize,
        ) -> bool {
            let mmr = self.mmr.read(mmr_id);
            // TODO error handling
            mmr.verify_proof(index, blockhash, peaks, proof).unwrap()
        }

        fn verify_historical_mmr_inclusion(
            self: @ContractState,
            index: usize,
            blockhash: felt252,
            peaks: Peaks,
            proof: Proof,
            mmr_id: usize,
            last_pos: usize,
        ) -> bool {
            // TODO error handling
            let root = self.mmr_history.read((mmr_id, last_pos));
            let mmr = MMRTrait::new(root, last_pos);
            mmr.verify_proof(index, blockhash, peaks, proof).unwrap()
        }

        fn create_branch_from_message(ref self: ContractState, root: felt252, last_pos: usize) {
            let caller = get_caller_address();
            assert(caller == self.commitments_inbox.read(), 'Only CommitmentsInbox');

            let mmr_id = self.latest_mmr_id.read() + 1;
            let mmr = MMRTrait::new(root, last_pos);
            self.mmr.write(mmr_id, mmr);
            self.mmr_history.write((mmr_id, last_pos), root);
            self.latest_mmr_id.write(mmr_id);

            self.emit(Event::BranchCreated(BranchCreated {
                mmr_id,
                root,
                last_pos
            }));
        }

        fn create_branch_single_element(
            ref self: ContractState,
            index: usize, 
            blockhash: felt252,
            peaks: Peaks,
            proof: Proof,
            mmr_id: usize,
        ) {
            assert(HeadersStore::verify_mmr_inclusion(@self, index, blockhash, peaks, proof, mmr_id), 'Invalid proof');

            let mut mmr: MMR = Default::default();
            mmr.append(blockhash, array![].span());

            let root = mmr.root;
            let last_pos = mmr.last_pos;

            let latest_mmr_id = self.latest_mmr_id.read() + 1;
            self.mmr.write(latest_mmr_id, mmr);
            self.mmr_history.write((latest_mmr_id, last_pos), root);
            self.latest_mmr_id.write(latest_mmr_id);


            self.emit(Event::BranchCreated(BranchCreated {
                mmr_id: latest_mmr_id,
                root,
                last_pos
            }));
        }

        fn create_branch_from(ref self: ContractState, mmr_id: usize) {
            let latest_mmr_id = self.latest_mmr_id.read() + 1;
            let mmr = self.mmr.read(mmr_id);

            let root = mmr.root;
            let last_pos = mmr.last_pos;

            self.mmr.write(latest_mmr_id, mmr.clone());
            self.mmr_history.write((latest_mmr_id, last_pos), root);
            self.latest_mmr_id.write(latest_mmr_id);

            self.emit(Event::BranchCreated(BranchCreated {
                mmr_id: latest_mmr_id,
                root,
                last_pos
            }));
        }
    }

    #[generate_trait]
    impl InternalFunctions of InternalFunctionsTrait {
        fn poseidon_hash_rlp(rlp: Words64) -> felt252 {
            // TODO refactor hashing logic
            let mut rlp_felt_arr: Array<felt252> = ArrayTrait::new();
            let mut i: usize = 0;
            loop {
                if i >= rlp.len() {
                    break ();
                }

                rlp_felt_arr.append((*rlp.at(i)).into());
                i += 1;
            };
            
            PoseidonHasher::hash_many(rlp_felt_arr.span())
        }
    }
}
