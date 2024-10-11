# PROV OAI Harvester

Version 0.1.0

## Description

PROV OAI Harvester is a Ruby script designed to harvest metadata records from OAI-PMH (Open Archives Initiative Protocol for Metadata Harvesting) endpoints. It specifically targets the Public Record Office Victoria (PROV) OAI-PMH endpoint but can be adapted for other OAI-PMH services.

## Features

- Harvests metadata records from OAI-PMH endpoints
- Supports resumption tokens for paginated requests
- Saves raw XML responses
- Generates a combined, sorted XML file of all records
- Produces a sorted JSON file of all records
- Can process previously saved XML files instead of making new requests

## Requirements

- Ruby 2.7 or higher
- Nokogiri gem
- OpenURI gem
- Other standard Ruby libraries (uri, json, date, fileutils, optparse)

## Installation

1. Ensure you have Ruby installed on your system.
2. Install the required gem:

```
bundle install
```

## Usage

Run the script from the command line:

```
bundle exec ruby harvest-prov-oai.rb [options]
```

### Options

- `-s, --save-raw-xml DIR`: Save raw XML to the specified directory.
- `-u, --use-saved-raw-xml DIR`: Use saved XML from the specified directory instead of making new requests.
- `--split`: Split into separate files for agencies, functions and series
- `-h, --help`: Print help information.
- `-v, --version`: Print version information.

### Example

To harvest records from the PROV OAI-PMH endpoint:

```
bundle exec ruby harvest-prov-oai.rb
```

To process previously saved XML files:

```
bundle exec ruby harvest-prov-oai.rb -u /path/to/saved/xml/directory
```

## Output

The script generates the following outputs:

1. A JSON file containing all harvested records, sorted by identifier.
2. An XML file containing all harvested records, sorted by identifier.

Output files are named with the current date, e.g., `prov-oai-2024-10-10.json`.

If `--save-xml DIR` is specified it will also create that DIR and save the raw XML responses inside it.

## Customisation

To use this script with a different OAI-PMH endpoint, modify the `base_url` variable in the script:

```ruby
base_url = 'http://your-oai-endpoint-url'
```

## License

This project is open source and is licensed under the Apache License, Version 2.0, ([LICENSE](LICENSE) or
https://www.apache.org/licenses/LICENSE-2.0).

