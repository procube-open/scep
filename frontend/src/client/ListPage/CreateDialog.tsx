import React, { useState, ChangeEvent } from 'react';
import {
  Dialog,
  DialogTitle,
  DialogContent,
  TextField,
  DialogActions,
  Button,
  MenuItem
} from '@mui/material';
import {
  useTranslate,
  useDataProvider,
  useNotify,
  useRefresh
} from 'react-admin';

interface CreateDialogProps {
  open: boolean;
  handleClose: () => void;
}

const CreateDialog: React.FC<CreateDialogProps> = ({ open, handleClose }) => {
  const windowsMSIManagedClientType = 'windows-msi';
  const [userId, setUserId] = useState<string>('');
  const [managedClientType, setManagedClientType] = useState<string>('');
  const [deviceId, setDeviceId] = useState<string>('');
  const [additionalAttributes, setAdditionalAttributes] = useState<string>('{}');
  const [userIdError, setUserIdError] = useState<boolean>(false);
  const [deviceIdError, setDeviceIdError] = useState<boolean>(false);
  const [additionalAttributesParseError, setAdditionalAttributesParseError] = useState<boolean>(false);
  const translate = useTranslate();
  const dataProvider = useDataProvider();
  const notify = useNotify();
  const refresh = useRefresh();

  const handleUserIdChange = (event: ChangeEvent<HTMLInputElement>) => {
    setUserId(event.target.value);
    if (event.target.value.trim() === '') {
      setUserIdError(true);
    } else {
      setUserIdError(false);
    }
  };

  const handleManagedClientTypeChange = (event: ChangeEvent<HTMLInputElement>) => {
    setManagedClientType(event.target.value);
    if (event.target.value !== windowsMSIManagedClientType) {
      setDeviceId('');
      setDeviceIdError(false);
    }
  };

  const handleDeviceIdChange = (event: ChangeEvent<HTMLInputElement>) => {
    setDeviceId(event.target.value);
    if (event.target.value.trim() === '') {
      setDeviceIdError(managedClientType === windowsMSIManagedClientType);
    } else {
      setDeviceIdError(false);
    }
  };

  const handleAdditionalAttributesChange = (event: ChangeEvent<HTMLInputElement>) => {
    setAdditionalAttributes(event.target.value);
    try {
      JSON.parse(event.target.value);
      setAdditionalAttributesParseError(false);
    } catch (e) {
      setAdditionalAttributesParseError(true);
    }
  };

  const resetForm = () => {
    setUserId('');
    setManagedClientType('');
    setDeviceId('');
    setAdditionalAttributes('{}');
    setUserIdError(false);
    setDeviceIdError(false);
    setAdditionalAttributesParseError(false);
  };

  const handleDialogClose = () => {
    resetForm();
    handleClose();
  };

  const handleSave = () => {
    let isValid = true;
    let parsedAttributes: Record<string, unknown> = {};
    if (userId.trim() === '') {
      setUserIdError(true);
      isValid = false;
    } else {
      setUserIdError(false);
    }

    if (managedClientType === windowsMSIManagedClientType && deviceId.trim() === '') {
      setDeviceIdError(true);
      isValid = false;
    } else {
      setDeviceIdError(false);
    }

    try {
      const parsed = JSON.parse(additionalAttributes);
      if (parsed === null || Array.isArray(parsed) || typeof parsed !== 'object') {
        throw new Error('attributes must be an object');
      }
      parsedAttributes = parsed as Record<string, unknown>;
      setAdditionalAttributesParseError(false);
    } catch (e) {
      setAdditionalAttributesParseError(true);
      isValid = false;
    }

    if (isValid) {
      const attributes = { ...parsedAttributes };
      delete attributes.managed_client_type;
      delete attributes.device_id;
      if (managedClientType === windowsMSIManagedClientType) {
        attributes.managed_client_type = windowsMSIManagedClientType;
        attributes.device_id = deviceId.trim();
      }

      dataProvider.createOne('client', { uid: userId.trim(), attributes: JSON.stringify(attributes) })
        .then(() => {
          notify('client.created', { type: 'success' });
          handleDialogClose();
          refresh();
        })
        .catch((e: Error) => {
          notify(`Error: ${e.message}`, { type: 'error' });
        });
    }
  };

  return (
    <Dialog open={open} onClose={handleDialogClose} fullWidth maxWidth={"md"}>
      <DialogTitle>{translate("client.dialog.title")}</DialogTitle>
      <DialogContent>
        <TextField
          autoFocus
          margin="dense"
          id="userId"
          label={translate("client.fields.uid")}
          type="text"
          fullWidth
          value={userId}
          onChange={handleUserIdChange}
          error={userIdError}
          helperText={userIdError ? translate("error.requiredError") : ''}
        />
        <TextField
          margin="dense"
          id="managedClientType"
          label={translate("client.fields.managed_client_type")}
          select
          fullWidth
          value={managedClientType}
          onChange={handleManagedClientTypeChange}
        >
          <MenuItem value="">
            {translate("client.managedClientType.none")}
          </MenuItem>
          <MenuItem value={windowsMSIManagedClientType}>
            {translate("client.managedClientType.windows_msi")}
          </MenuItem>
        </TextField>
        <TextField
          margin="dense"
          id="deviceId"
          label={translate("client.fields.device_id")}
          type="text"
          fullWidth
          value={deviceId}
          onChange={handleDeviceIdChange}
          error={deviceIdError}
          disabled={managedClientType !== windowsMSIManagedClientType}
          helperText={deviceIdError ? translate("error.requiredError") : managedClientType === windowsMSIManagedClientType ? translate("client.fields.device_id_helper") : ''}
        />
        <TextField
          margin="dense"
          id="additionalAttributes"
          label={translate("client.fields.additional_attributes")}
          type="text"
          fullWidth
          multiline
          minRows={4}
          value={additionalAttributes}
          onChange={handleAdditionalAttributesChange}
          error={additionalAttributesParseError}
          helperText={additionalAttributesParseError ? translate("error.parseError") : ''}
        />
      </DialogContent>
      <DialogActions>
        <Button onClick={handleDialogClose} color="primary">
          {translate("ra.action.cancel")}
        </Button>
        <Button onClick={handleSave} color="primary">
          {translate("ra.action.save")}
        </Button>
      </DialogActions>
    </Dialog>
  );
};


export default CreateDialog;
