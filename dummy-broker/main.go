package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"example.com/benchbase/dummy-broker/commons"
)

func main() {
	listen := flag.String("listen", ":8080", "HTTP listen address, e.g. :8080")
	outFile := flag.String("out", "", "Path to the per-broker transaction log (.txt); default transactions/broker-<id>/transactions.txt under -transactions-root")
	brokerID := flag.String("broker-id", "1", "Broker id (used for default output path)")
	txRoot := flag.String("transactions-root", "transactions", "Root directory for default per-broker log layout")
	flag.Parse()

	path := *outFile
	if path == "" {
		path = filepath.Join(*txRoot, fmt.Sprintf("broker-%s", *brokerID), "transactions.txt")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		log.Fatalf("mkdir: %v", err)
	}

	b := &Broker{logPath: path, mu: &sync.Mutex{}}
	mux := http.NewServeMux()
	mux.HandleFunc("/addTransaction", b.handleTransactionRequest)
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	log.Printf("dummy broker id=%s listening on %s logging to %s", *brokerID, *listen, path)
	if err := http.ListenAndServe(*listen, mux); err != nil {
		log.Fatal(err)
	}
}

type Broker struct {
	logPath string
	mu      *sync.Mutex
}

func (b *Broker) handleTransactionRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("read body: %v", err)
		http.Error(w, "Error reading request body", http.StatusBadRequest)
		return
	}
	defer r.Body.Close()

	transaction := &commons.Transaction{}
	if err := json.Unmarshal(body, transaction); err != nil {
		log.Printf("unmarshal: %v", err)
		http.Error(w, "Error unmarshaling request body", http.StatusBadRequest)
		return
	}

	line, err := json.Marshal(transaction)
	if err != nil {
		log.Printf("marshal for log: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	b.mu.Lock()
	f, err := os.OpenFile(b.logPath, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		b.mu.Unlock()
		log.Printf("open log: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	_, werr := f.Write(append(line, '\n'))
	cerr := f.Close()
	b.mu.Unlock()

	if werr != nil || cerr != nil {
		log.Printf("write log: werr=%v cerr=%v", werr, cerr)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	log.Printf("received transaction id=%d type=%d ts=%s ops=%d", transaction.Id, transaction.TransactionType, transaction.Timestamp.String(), len(transaction.Operations))
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprintf(w, `{"status":"ok","written_at":"%s"}`, time.Now().UTC().Format(time.RFC3339Nano))
}
