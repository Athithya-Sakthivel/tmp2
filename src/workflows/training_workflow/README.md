# Training Workflow

## TL;DR
```sh
training_workflow/                     # Root directory containing the Flyte training pipeline implementation and runtime configuration.
│
├── Dockerfile.train                  # Container specification defining the reproducible runtime environment used by Flyte tasks during training execution.
├── requirements.txt                  # Python dependency list used to build the training container with ML, data processing, validation, and registry libraries.
├── flyte_training_workflow.py        # Flyte workflow definition that wires all training tasks into a DAG and specifies execution order, inputs, and outputs.
│
└── tasks/                            # Collection of individual Flyte task modules representing atomic pipeline steps executed in the workflow.
    ├── extract_load_data.py          # Task that reads historical partitions from the offline data store and constructs the raw dataset snapshot for training.
    ├── raw_data_validation.py        # Task that validates structural integrity of the raw dataset (schema, nulls, duplicates, timestamps) before transformations.
    ├── ray_data_preprocessing.py     # Task that performs distributed feature engineering, joins, aggregations, and dataset splitting using Ray Data.
    ├── feature_validation.py         # Task that validates engineered features for range correctness, categorical domains, and label distributions.
    ├── train_and_evaluate_model.py   # Task that performs hyperparameter search, trains the candidate model, and evaluates it against validation metrics.
    └── export_and_register_model.py  # Task that converts the trained model to ONNX, uploads artifacts to storage, and registers the model version in MLflow.
```

## Overview

The **training workflow** is the automated pipeline responsible for producing deployable machine learning model artifacts. It orchestrates dataset extraction, validation, distributed preprocessing, model training, evaluation, and artifact registration.

The workflow is executed and scheduled using **Flyte** and produces versioned model artifacts registered in **MLflow**. Feature processing is performed using **Ray Data**, and data quality validation is performed with **Great Expectations**.

Outputs from this workflow are consumed by the deployment pipeline, which loads the exported model artifacts into the serving infrastructure.

---

# Repository Structure

```
src/workflows/training_workflow/

Dockerfile.train
requirements.txt
flyte_training_workflow.py

tasks/
    extract_load_data.py
    raw_data_validation.py
    ray_data_preprocessing.py
    feature_validation.py
    train_and_evaluate_model.py
    export_and_register_model.py
```

---

# Workflow Responsibilities

The training workflow performs the following responsibilities:

1. Extract historical data required for training.
2. Validate raw datasets for schema and integrity.
3. Perform distributed feature preprocessing.
4. Validate engineered features and label distributions.
5. Train and evaluate candidate models.
6. Export the approved model artifact.
7. Register the model version and metadata.

Each stage is implemented as an isolated **Flyte task** to ensure reproducibility, retry isolation, and artifact lineage.

---

# Execution Flow

The workflow executes tasks in the following order:

```
extract_load_data
        ↓
raw_data_validation
        ↓
ray_data_preprocessing
        ↓
feature_validation
        ↓
train_and_evaluate_model
        ↓
export_and_register_model
```

The output of each task becomes the input to the next stage.

---

# Tasks

## extract_load_data

### Purpose

Extract training data from the offline data store and assemble the raw dataset snapshot used for training.

### Responsibilities

* Read historical partitions from the offline feature store or data lake.
* Load required feature columns and labels.
* Construct the raw dataset used for downstream preprocessing.

### Inputs

* Dataset time window
* Feature schema version
* Table or dataset identifiers

### Outputs

* Raw dataset snapshot
* Dataset metadata

---

## raw_data_validation

### Purpose

Verify structural integrity of the raw dataset before performing transformations.

### Responsibilities

Run data quality checks including:

* Schema validation
* Null checks
* Duplicate primary key detection
* Timestamp integrity validation
* Partition completeness checks

### Implementation

Validation rules are executed using **Great Expectations**.

### Failure Behavior

If validation fails, the workflow terminates and the failure is recorded in Flyte execution logs.

### Outputs

* Validation report
* Verified dataset reference

---

## ray_data_preprocessing

### Purpose

Transform raw data into a model-ready dataset using distributed processing.

### Responsibilities

Feature engineering and dataset preparation including:

* Feature joins
* Aggregations and rolling windows
* Feature normalization
* Categorical encoding
* Label construction
* Train/validation split generation

### Implementation

Processing is executed using **Ray Data** for scalable distributed data transformation.

### Outputs

* Feature-engineered dataset
* Training dataset
* Validation dataset

---

## feature_validation

### Purpose

Validate engineered features before training.

### Responsibilities

Ensure feature correctness after preprocessing.

Validation checks include:

* Feature value ranges
* Distribution sanity checks
* Categorical domain validation
* Label distribution verification

### Implementation

Validation is implemented using Great Expectations and additional statistical checks.

### Failure Behavior

If feature validation fails, the workflow stops before model training begins.

### Outputs

* Validated feature dataset
* Feature validation report

---

## train_and_evaluate_model

### Purpose

Train candidate models and evaluate performance.

### Responsibilities

* Perform hyperparameter search.
* Train models on the prepared dataset.
* Evaluate model performance on the validation dataset.
* Compare candidate model performance against baseline metrics.

### Implementation

Model training uses:

* **FLAML** for hyperparameter optimization
* **LightGBM** for gradient boosting model training

### Evaluation Metrics

Typical metrics include:

* AUC
* Accuracy
* Precision / Recall
* RMSE

### Outputs

* Trained model artifact
* Evaluation metrics
* Promotion decision flag

---

## export_and_register_model

### Purpose

Export the trained model as a deployable artifact and register it in the model registry.

### Responsibilities

* Convert the trained model to ONNX format.
* Upload the artifact to object storage.
* Register a new model version in MLflow.
* Attach metadata including training run identifiers and evaluation metrics.

### Implementation

Models are exported for inference using **ONNX Runtime** compatible format.

### Outputs

* ONNX model artifact URI
* MLflow model version
* Training run metadata

---

# Container Environment

## Dockerfile.train

Defines the runtime container used by Flyte task execution.

The container includes all dependencies required for:

* distributed data processing
* dataset validation
* model training
* model export
* artifact registration

The container image ensures consistent execution across development, CI pipelines, and production environments.

---

# Dependencies

## requirements.txt

Defines the Python dependencies required by the training workflow.

Typical dependency categories include:

* workflow orchestration libraries
* distributed data processing frameworks
* machine learning libraries
* dataset validation frameworks
* artifact storage clients
* model registry clients

All dependencies are installed during container build and bundled in the training runtime image.

---

# Artifacts Produced

Each successful workflow execution produces the following artifacts:

* raw dataset snapshot
* preprocessing dataset outputs
* validation reports
* trained model artifact
* evaluation metrics
* ONNX model artifact
* MLflow model version
* training metadata

Artifacts are stored in object storage and referenced by Flyte execution metadata.

---

# Integration With Platform

The training workflow integrates with other platform pipelines:

* Feature ingestion workflows populate the offline dataset used for training.
* Monitoring workflows detect model drift and trigger retraining.
* Deployment workflows consume exported model artifacts and update serving infrastructure.

These pipelines together form the end-to-end model lifecycle management system.
