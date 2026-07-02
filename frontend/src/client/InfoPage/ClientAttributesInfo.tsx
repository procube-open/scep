import React from 'react';
import {
  Box,
  Button,
  Card,
  CardContent,
  MenuItem,
  TextField,
  Typography,
} from '@mui/material';
import {
  useDataProvider,
  useNotify,
  useRefresh,
  useTranslate,
} from 'react-admin';
import { useQuery } from 'react-query';

interface ClientAttributesInfoProps {
  uid: string | undefined;
}

interface ClientAttributesFormState {
  managedClientType: string;
  deviceId: string;
  additionalAttributes: string;
}

const windowsMSIManagedClientType = 'windows-msi';

const emptyFormState: ClientAttributesFormState = {
  managedClientType: '',
  deviceId: '',
  additionalAttributes: '{}',
};

const parseClientAttributes = (value: unknown): Record<string, unknown> => {
  if (value === null || value === undefined) {
    return {};
  }
  if (typeof value === 'string') {
    const parsed = JSON.parse(value);
    if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
      throw new Error('attributes must be an object');
    }
    return parsed as Record<string, unknown>;
  }
  if (Array.isArray(value) || typeof value !== 'object') {
    throw new Error('attributes must be an object');
  }
  return value as Record<string, unknown>;
};

const toFormState = (attributes: Record<string, unknown>): ClientAttributesFormState => {
  const additionalAttributes = { ...attributes };
  const managedClientType = additionalAttributes.managed_client_type === windowsMSIManagedClientType
    ? windowsMSIManagedClientType
    : '';
  const deviceId = typeof additionalAttributes.device_id === 'string'
    ? additionalAttributes.device_id
    : '';

  delete additionalAttributes.managed_client_type;
  delete additionalAttributes.device_id;

  return {
    managedClientType,
    deviceId,
    additionalAttributes: JSON.stringify(additionalAttributes, null, 2),
  };
};

const ClientAttributesInfo = (props: ClientAttributesInfoProps) => {
  const { uid } = props;
  const dataProvider = useDataProvider();
  const translate = useTranslate();
  const notify = useNotify();
  const refresh = useRefresh();
  const [params, setParams] = React.useState<ClientAttributesFormState>(emptyFormState);
  const [deviceIdError, setDeviceIdError] = React.useState(false);
  const [additionalAttributesParseError, setAdditionalAttributesParseError] = React.useState(false);
  const [saving, setSaving] = React.useState(false);

  const clientQuery = useQuery({
    queryKey: ['client-attributes', uid],
    enabled: !!uid,
    queryFn: () => dataProvider.getOne('client', { id: uid }).then((json: any) => json.data),
  });

  React.useEffect(() => {
    if (!clientQuery.data) {
      return;
    }
    try {
      const attributes = parseClientAttributes(clientQuery.data.attributes);
      setParams(toFormState(attributes));
      setDeviceIdError(false);
      setAdditionalAttributesParseError(false);
    } catch {
      setParams(emptyFormState);
      setAdditionalAttributesParseError(true);
    }
  }, [clientQuery.data]);

  const handleSave = () => {
    if (!uid) {
      return;
    }

    let isValid = true;
    let parsedAdditionalAttributes: Record<string, unknown> = {};
    const trimmedDeviceId = params.deviceId.trim();

    if (params.managedClientType === windowsMSIManagedClientType && trimmedDeviceId === '') {
      setDeviceIdError(true);
      isValid = false;
    } else {
      setDeviceIdError(false);
    }

    try {
      const parsed = JSON.parse(params.additionalAttributes);
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        throw new Error('attributes must be an object');
      }
      parsedAdditionalAttributes = parsed as Record<string, unknown>;
      setAdditionalAttributesParseError(false);
    } catch {
      setAdditionalAttributesParseError(true);
      isValid = false;
    }

    if (!isValid) {
      return;
    }

    const attributes = { ...parsedAdditionalAttributes };
    delete attributes.managed_client_type;
    delete attributes.device_id;
    if (params.managedClientType === windowsMSIManagedClientType) {
      attributes.managed_client_type = windowsMSIManagedClientType;
    }
    if (trimmedDeviceId !== '') {
      attributes.device_id = trimmedDeviceId;
    }

    setSaving(true);
    dataProvider.updateOne('client', { uid, attributes: JSON.stringify(attributes) })
      .then(async () => {
        notify('client.updated', { type: 'success' });
        await clientQuery.refetch();
        refresh();
      })
      .catch((e: Error) => {
        notify(e.message ? `Error: ${e.message}` : 'error.updateError', { type: 'error' });
      })
      .finally(() => {
        setSaving(false);
      });
  };

  if (!uid) {
    return null;
  }

  return (
    <Box sx={{ width: 1, mt: 2 }}>
      <Typography variant="h5" sx={{ mb: 2 }}>
        {translate('client.updateTitle')}
      </Typography>
      <Card sx={{ width: 1 }}>
        <CardContent>
          <TextField
            margin="dense"
            label={translate('client.fields.managed_client_type')}
            select
            fullWidth
            value={params.managedClientType}
            disabled={clientQuery.isLoading || saving}
            onChange={(event) => setParams({ ...params, managedClientType: event.target.value })}
          >
            <MenuItem value="">
              {translate('client.managedClientType.none')}
            </MenuItem>
            <MenuItem value={windowsMSIManagedClientType}>
              {translate('client.managedClientType.windows_msi')}
            </MenuItem>
          </TextField>
          <TextField
            margin="dense"
            label={translate('client.fields.device_id')}
            fullWidth
            value={params.deviceId}
            disabled={clientQuery.isLoading || saving}
            onChange={(event) => {
              setParams({ ...params, deviceId: event.target.value });
              if (event.target.value.trim() !== '') {
                setDeviceIdError(false);
              }
            }}
            error={deviceIdError}
            helperText={
              deviceIdError
                ? translate('error.requiredError')
                : translate('client.fields.device_id_helper')
            }
          />
          <TextField
            margin="dense"
            label={translate('client.fields.additional_attributes')}
            fullWidth
            multiline
            minRows={4}
            value={params.additionalAttributes}
            disabled={clientQuery.isLoading || saving}
            onChange={(event) => {
              setParams({ ...params, additionalAttributes: event.target.value });
              setAdditionalAttributesParseError(false);
            }}
            error={additionalAttributesParseError}
            helperText={additionalAttributesParseError ? translate('error.parseError') : ''}
          />
          <Box sx={{ display: 'flex', justifyContent: 'flex-end', mt: 2 }}>
            <Button
              variant="contained"
              color="primary"
              onClick={handleSave}
              disabled={clientQuery.isLoading || saving}
            >
              {translate('ra.action.save')}
            </Button>
          </Box>
        </CardContent>
      </Card>
    </Box>
  );
};

export default ClientAttributesInfo;
