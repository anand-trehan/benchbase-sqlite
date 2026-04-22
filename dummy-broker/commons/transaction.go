package commons

import "github.com/dgraph-io/badger/v4/types"

type Operation struct {
	Key   string `json:"key"`
	Value string `json:"value"`
	Op    int64  `json:"op"` // Operation type: 1 (Write), 2 (Delete), 3 (Read)
}

type Transaction struct {
	Id              int64            `json:"id"`
	Timestamp       types.CustomTs   `json:"timestamp"`
	Operations      []*Operation     `json:"operations"`
	TransactionType int              `json:"TransactionType"`
}
