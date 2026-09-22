                        String status;
                        if (modelsAsync.isLoading && apiKey.isNotEmpty) {
                          status = 'Fetching models from Groq…';
                        } else if (liveModels.isNotEmpty) {
                          status =
                              '${liveModels.length} models from the Groq API';
                        } else if (modelsAsync.hasError) {
                          status =
                              'Could not reach Groq — using the default list';
                        } else {
                          status =
                              'Default list — save an API key to sync with Groq';
                        }

                        return Container(
                          padding: const EdgeInsets.all(DesignTokens.space4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('AI Model',
                                        style: TextStyle(
                                            color: cs.onSurface,
                                            fontWeight:
                                                DesignTokens.fontWeightMedium,
                                            fontSize: DesignTokens.fontSizeMD)),
                                    const SizedBox(height: 2),
                                    Text(status,
                                        style: TextStyle(
                                            color: cs.onSurfaceVariant,
                                            fontSize: DesignTokens.fontSizeSM)),
                                  ],
                                ),
                              ),
                              const SizedBox(width: DesignTokens.space3),
                              SizedBox(
                                width: 220,
                                child: Material(
                                  child: DropdownButton<String>(
                                    key: const Key('groq-model-dropdown'),
                                    value: models.contains(currentModel)
                                        ? currentModel
                                        : models.first,
                                    isExpanded: true,
                                    items: models
                                        .map((m) => DropdownMenuItem(
                                            value: m,
                                            child: Text(m,
                                                overflow: TextOverflow.ellipsis,
                                                style:
                                                    TextStyle(fontSize: 12))))
                                        .toList(),
                                    onChanged: (value) async {
                                      if (value != null) {
                                        await settingsService.setModel(value);