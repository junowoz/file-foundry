# File Foundry — Media Organizer Safety Model

## Ameaças e boundaries

**Path incorreto:** `ReadOnlySourceURL`, `DestinationRoot`, `WritableDestinationURL` e `FileSystemPolicy` separam leitura e escrita. Caminhos absolutos, `..`, escapes por symlink e roots sobrepostos falham fechados.

**Sobrescrita:** cada operação cria um output exclusivo. O planner resolve colisões deterministicamente e o motor verifica novamente a existência antes do commit. Não existe Replace.

**Cópia corrompida:** origem e staging são calculados independentemente com SHA-256 em streaming. O arquivo final só nasce quando os hashes coincidem; depois do commit o hash final é recalculado.

**Origem muda durante a cópia:** tamanho, mtime, resource identifier e SHA-256 são comparados antes/depois. A transação não finaliza se houver mudança.

**Symlink ou package:** o scanner registra e não segue symlinks; packages não são percorridos.

**Troca concorrente de symlink no destino:** a cadeia de ancestrais e seus resource identifiers é revalidada antes/depois da criação e antes dos relatórios. Isso reduz a janela, mas Foundation não oferece commit descriptor-relative; a limitação permanece documentada e o destino não deve ser alterado por outro processo durante a cópia.

**Disco cheio/desconectado/crash:** a origem nunca é tocada. Parciais ficam em staging dentro do output. A versão atual ainda não retoma automaticamente uma operação após relaunch.

**Undo inseguro:** Undo ainda não existe. Ele só será adicionado quando puder validar manifest, hash atual do destino, existência e hash atual da origem antes de remover qualquer cópia.

## APIs proibidas

Não há networking, CloudKit, Photos write API, metadata write API ou write handle de origem. `script/safety_audit.sh` falha diante de APIs destrutivas fora da allowlist e integrações de rede/cloud.
