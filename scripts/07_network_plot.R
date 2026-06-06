# ==============================================================================
# BLM3810 Biyoenformatiğe Giriş - Proje
# Script 07: WGCNA Hub Gen Merkezli Co-expression Ağı (igraph)
# En trait-korelasyonlu modül (best_module) otomatik kullanılır.
# ==============================================================================

library(igraph)
library(scales)

BASE_DIR <- getwd()
FIG_DIR  <- file.path(BASE_DIR, "results", "figures")
DATA_DIR <- file.path(BASE_DIR, "data")
TAB_DIR  <- file.path(BASE_DIR, "results", "tables")
dir.create(FIG_DIR, recursive = TRUE, showWarnings = FALSE)

# --- WGCNA sonuçları ---
wgcna <- readRDS(file.path(DATA_DIR, "wgcna_results.rds"))
df    <- readRDS(file.path(DATA_DIR, "expr_matrix.rds"))   # samples x genes

moduleColors <- wgcna$moduleColors
TOM          <- wgcna$TOM
best_module  <- wgcna$best_module
message(paste(">>> Network için modül:", best_module))

# --- Hub genleri CSV'den, seçilen modüle göre al ---
hub_csv <- read.csv(file.path(TAB_DIR, "hub_genes_per_module.csv"), stringsAsFactors = FALSE)
mod_hubs <- hub_csv$gene[hub_csv$module == best_module]
message(paste("Hub genler:", paste(mod_hubs, collapse = ", ")))

# --- Modül genleri ve TOM alt matrisi ---
mod_idx       <- moduleColors == best_module
mod_genes     <- colnames(df)[mod_idx]
mod_tom       <- TOM[mod_idx, mod_idx]
dimnames(mod_tom) <- list(mod_genes, mod_genes)

# --- Hub merkezli alt ağ: her hub genin en yakın komşuları ---
mod_hubs <- mod_hubs[mod_hubs %in% mod_genes]
if (length(mod_hubs) == 0) stop("Seçilen modülde hub gen bulunamadı.")

neighbors <- unique(unlist(lapply(mod_hubs, function(h) {
  names(sort(mod_tom[h, ], decreasing = TRUE))[1:15]
})))
neighbors <- unique(c(neighbors, mod_hubs))
neighbors <- neighbors[neighbors %in% mod_genes]
message(paste("Alt ağ gen sayısı:", length(neighbors)))

sub_tom   <- mod_tom[neighbors, neighbors]
threshold <- quantile(sub_tom[upper.tri(sub_tom)], 0.6)

# --- Kenar listesi ---
edges_list <- list(); k <- 1
for (i in 1:(length(neighbors) - 1)) {
  for (j in (i + 1):length(neighbors)) {
    w <- sub_tom[i, j]
    if (w > threshold) {
      edges_list[[k]] <- data.frame(from = neighbors[i], to = neighbors[j], weight = w)
      k <- k + 1
    }
  }
}
edges_df <- do.call(rbind, edges_list)
message(paste("Kenar sayısı:", nrow(edges_df)))

g <- graph_from_data_frame(edges_df, directed = FALSE)

# Modül rengini node rengi için kullan (grey ise kahverengi yedek)
node_col <- if (best_module %in% colors()) best_module else "#8B4513"

V(g)$is_hub      <- V(g)$name %in% mod_hubs
V(g)$size        <- ifelse(V(g)$is_hub, 14, 4 + degree(g) / 2)
V(g)$color       <- ifelse(V(g)$is_hub, "#E64B35", scales::alpha(node_col, 0.6))
V(g)$label       <- ifelse(V(g)$is_hub | degree(g) >= quantile(degree(g), 0.8), V(g)$name, NA)
V(g)$label.cex   <- ifelse(V(g)$is_hub, 0.9, 0.6)
V(g)$label.color <- "black"
V(g)$label.font  <- ifelse(V(g)$is_hub, 2, 1)
V(g)$frame.color <- ifelse(V(g)$is_hub, "black", NA)
E(g)$width <- scales::rescale(E(g)$weight, to = c(0.3, 2.5))
E(g)$color <- scales::alpha("grey40", 0.4)

set.seed(123)
out_file <- file.path(FIG_DIR, paste0("network_", best_module, "_module.png"))
png(out_file, width = 12, height = 10, units = "in", res = 300)
par(mar = c(1, 1, 3, 1))
plot(g, layout = layout_with_fr(g),
     main = paste0(tools::toTitleCase(best_module),
                   " Module Hub Gene Network (Top TOM Connections)"))
legend("bottomright",
       legend = c("Hub Gene", "Connected Gene"),
       col = c("#E64B35", scales::alpha(node_col, 0.6)),
       pch = 19, pt.cex = c(2.5, 1.2), cex = 0.9, bty = "n")
dev.off()

message(paste(">>> Kaydedildi:", out_file))
message(paste("Nodes:", vcount(g), "| Edges:", ecount(g), "| Hubs:", sum(V(g)$is_hub)))
