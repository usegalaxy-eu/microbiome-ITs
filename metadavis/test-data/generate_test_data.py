#!/usr/bin/env python3
"""Generate the reusable MetaDAVis Galaxy IT test dataset.

Produces a phyloseq-style triplet in test-data/:

  otu_table.tsv       features (rows) x samples (columns), integer counts
  taxonomy_table.tsv  #OTU_ID + 7 canonical ranks, values carry k__/p__/...
                      rank prefixes so the parser has to strip them
  metadata_table.tsv  SampleID + Condition + further sample annotations

Column order in the metadata table matters: the first column is the sample id
("Samples" downstream) and the second is the grouping condition, because the
plotting code reads group_index[, 2]. Every column after that is carried
through to the displayed metadata table untouched.

The data are simulated, but shaped like a real amplicon run: 60 samples in
three conditions (CD / HC / UC), sparse counts with a long tail, covariates
that are correlated with the condition the way real confounders are, and a few
features that are deliberately left unannotated so the "Unclassified" handling
is exercised.

Usage:  python3 test-data/generate_test_data.py
"""

import random
from pathlib import Path

SEED = 20240501
N_FEATURES = 1000
CONDITIONS = ["CD", "HC", "UC"]
SAMPLES_PER_CONDITION = 20

# A small pool of real bacterial lineages, expanded combinatorially so that
# every generated feature carries a plausible, self-consistent lineage.
GENERA = [
    "Bacteroides", "Faecalibacterium", "Prevotella", "Ruminococcus",
    "Akkermansia", "Alistipes", "Blautia", "Roseburia", "Eubacterium",
    "Clostridium", "Lactobacillus", "Streptococcus", "Enterococcus",
    "Escherichia", "Klebsiella", "Akkermansia muciniphila",
    "Phocaeicola", "Bacteroides uniformis", "Parabacteroides",
]
FAMILIES = [
    "Bacteroidaceae", "Lachnospiraceae", "Clostridiaceae", "Ruminococcaceae",
    "Verrucomicrobiaceae", "Coriobacteriaceae", "Enterobacteriaceae",
    "Streptococcaceae", "Lactobacillaceae",
]
ORDERS = [
    "Bacteroidales", "Clostridiales", "Verrucomicrobiales", "Coriobacteriales",
    "Enterobacterales", "Bacillales",
]
CLASSES = [
    "Bacteroidia", "Clostridia", "Verrucomicrobia", "Coriobacteria",
    "Gammaproteobacteria", "Bacilli",
]
PHYLUM_ROLLOVER = {
    "Bacteroidia": "Bacteroidetes",
    "Clostridia": "Firmicutes",
    "Verrucomicrobia": "Verrucomicrobia",
    "Coriobacteria": "Actinobacteria",
    "Gammaproteobacteria": "Proteobacteria",
    "Bacilli": "Firmicutes",
}
SPECIES_EPITHETS = [
    "vulgatus", "uniformis", "distasonis", "fragilis", "intestinalis",
    "afecae", "copri", "subtilis", "sputicum", "longum", "breve", "castoris",
]

# Sample annotations beyond the grouping condition. These mirror the covariates
# that show up in real amplicon metadata, including ones that are confounded
# with the condition, which is what makes the dataset useful for testing.
SITES = ["Colonoscopy", "Clinic", "Research", "Screening"]
SEXES = ["Female", "Male"]
AGES = {"CD": (46, 74), "HC": (22, 45), "UC": (28, 66)}
BMI_RANGES = {"CD": (18.5, 24.0), "HC": (20.5, 26.5), "UC": (17.8, 23.2)}
BATCHES = ["PE250-B1", "PE250-B2"]
CONSISTENCY = ["forward", "reverse"]


def build_samples():
    samples = []
    for condition in CONDITIONS:
        for replicate in range(1, SAMPLES_PER_CONDITION + 1):
            samples.append(f"{condition}.{replicate:03d}")
    return samples


def build_taxonomy(rng, feature_ids):
    """Lineage per feature. The last two features stay unannotated on purpose."""
    rows = []
    unannotated = set(feature_ids[-2:])
    for feature in feature_ids:
        if feature in unannotated:
            rows.append([feature] + [""] * 7)
            continue
        klass = rng.choice(CLASSES)
        # A quarter of the features only carry a partial lineage, which is very
        # common in reference databases and exercises the rank fallback.
        partial = rng.random() < 0.25
        phylum = PHYLUM_ROLLOVER[klass]
        order = rng.choice(ORDERS)
        family = rng.choice(FAMILIES)
        genus = rng.choice(GENERA)
        species = f"{genus.split()[0]} {rng.choice(SPECIES_EPITHETS)}"
        lineage = [
            "k__Bacteria",
            f"p__{phylum}",
            f"c__{klass}",
            "" if partial else f"o__{order}",
            "" if partial else f"f__{family}",
            f"g__{genus}",
            "" if partial else f"s__{species}",
        ]
        rows.append([feature] + lineage)
    return rows


def build_counts(rng, feature_ids, samples):
    """Sparse counts with a long tail and a per-feature abundance profile."""
    # Each feature gets a "carried by" condition, so the stacked bar plot and
    # the group comparisons show real differences instead of noise.
    carriers = [rng.choice(CONDITIONS) for _ in feature_ids]
    rows = []
    for feature, carrier in zip(feature_ids, carriers):
        # Heavy-tailed feature abundance: a few dominant features, many rare.
        weight = rng.paretovariate(1.6)
        total = int(rng.lognormvariate(4.2, 1.1) * min(weight, 40))
        total = max(total, 0)
        counts = []
        for sample in samples:
            condition = sample.split(".")[0]
            base = total / len(samples)
            if condition == carrier:
                value = rng.lognormvariate(max(base, 1.0), 1.0)
            else:
                # Leaky but clearly lower off-carrier counts.
                value = rng.lognormvariate(max(base * 0.15, 0.2), 1.2)
            counts.append(int(min(value, 20000)))
        rows.append([feature] + counts)
    return rows


def build_metadata(rng, samples, otu_rows):
    """Sample annotations.

    The first two columns are load-bearing (sample id, grouping condition);
    the rest are carried through to the displayed metadata table. Ages and
    BMI ranges are condition-dependent on purpose so the metadata looks like
    real confounded clinical data rather than noise.
    """
    # Per-sample read depth, so a depth column agrees with the OTU table.
    depth = {}
    for row in otu_rows:
        for index, value in enumerate(row[1:]):
            sample = samples[index]
            depth[sample] = depth.get(sample, 0) + value

    rows = []
    for sample in samples:
        condition = sample.split(".")[0]
        low, high = AGES[condition]
        age = rng.randint(low, high)
        bmi_low, bmi_high = BMI_RANGES[condition]
        rows.append([
            sample,
            condition,
            rng.choice(SITES),
            rng.choice(SEXES),
            age,
            round(rng.uniform(bmi_low, bmi_high), 1),
            rng.choice(BATCHES),
            rng.choice(CONSISTENCY),
            # Sequencing depth in reads, formatted the way a run sheet reports it.
            f"{int(depth[sample] * rng.uniform(280.0, 340.0))}",
        ])
    return rows


def write_tsv(path, header, rows):
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write("\t".join(header) + "\n")
        for row in rows:
            handle.write("\t".join(str(cell) for cell in row) + "\n")


def main():
    rng = random.Random(SEED)
    out_dir = Path(__file__).resolve().parent
    feature_ids = [f"OTU{index:05d}" for index in range(1, N_FEATURES + 1)]
    samples = build_samples()

    otu_rows = build_counts(rng, feature_ids, samples)
    write_tsv(
        out_dir / "otu_table.tsv",
        ["#OTU_ID"] + samples,
        otu_rows,
    )
    write_tsv(
        out_dir / "taxonomy_table.tsv",
        ["#OTU_ID", "Kingdom", "Phylum", "Class", "Order", "Family", "Genus", "Species"],
        build_taxonomy(rng, feature_ids),
    )
    write_tsv(
        out_dir / "metadata_table.tsv",
        ["SampleID", "Condition", "Site", "Sex", "Age", "BMI", "Batch", "ReadDirection", "SequencingDepth"],
        build_metadata(rng, samples, otu_rows),
    )

    print(f"features: {N_FEATURES}")
    print(f"samples:  {len(samples)} ({SAMPLES_PER_CONDITION} per condition)")
    for name in ("otu_table.tsv", "taxonomy_table.tsv", "metadata_table.tsv"):
        path = out_dir / name
        print(f"{name}: {path.stat().st_size / 1024:.0f} kB")


if __name__ == "__main__":
    main()